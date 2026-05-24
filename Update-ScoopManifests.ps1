# 変更前 --------------------------------------------------
# $bucketPath = "$env:SCOOP\buckets\my-bucket"
# $logFile = "$bucketPath\update_log.txt"
# $date = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
# --------------------------------------------------------

# 変更後 --------------------------------------------------
# GitHub Actions環境かローカルPC環境かを自動判定
if ($env:GITHUB_WORKSPACE) {
    # GitHub Actions上のパス
    $bucketPath = "$env:GITHUB_WORKSPACE\bucket"
    $checkverScript = "$env:USERPROFILE\scoop\apps\scoop\current\bin\checkver.ps1"
} else {
    # 従来のローカルPC上のパス
    $bucketPath = "$env:SCOOP\buckets\my-bucket"
    $checkverScript = "$env:SCOOP\apps\scoop\current\bin\checkver.ps1"
}

$logFile = "$bucketPath\update_log.txt"
$date = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
# --------------------------------------------------------
# プログレスバー非表示
$ProgressPreference = 'SilentlyContinue'

try {
    $targetManifests = Get-ChildItem "$bucketPath\*.json"

    "$date - Update Check Started" | Out-File $logFile -Append -Encoding UTF8

    foreach ($file in $targetManifests) {
        $jsonPath = $file.FullName
        $fileName = $file.Name
        
        $checkOutput = & $checkverScript $jsonPath -NoColors *>&1 | Out-String
        
        if ($checkOutput -match '(?m)^\s*[\w-]+:\s+([^\s\r\n]+)') {
            $newVersion = $matches[1]
            $json = Get-Content $jsonPath -Raw | ConvertFrom-Json
            $oldVersion = $json.version

            if ($newVersion -ne $oldVersion) {
                $json.version = $newVersion

                # URLの更新処理（architectureがある場合とない場合の両方に対応）
                # $commit プレースホルダ用にバージョン後半部分を抽出（"timestamp.hash" 形式に対応）
                $commit = if ($newVersion -match '\.([0-9a-f]+)$') { $matches[1] } else { $newVersion }

                if ($json.architecture.'64bit'.url) {
                    # エミュレータ等の構造
                    $urlTemplate = $json.autoupdate.architecture.'64bit'.url
                    $newUrl = $urlTemplate.Replace('$version', $newVersion).Replace('$commit', $commit)
                    $json.architecture.'64bit'.url = $newUrl
                    $json.architecture.'64bit'.psobject.Properties.Remove('hash')

                    # extract_dir も更新（テンプレが定義されていれば）
                    if ($json.autoupdate.architecture.'64bit'.extract_dir) {
                        $extractTemplate = $json.autoupdate.architecture.'64bit'.extract_dir
                        $json.architecture.'64bit'.extract_dir = $extractTemplate.Replace('$version', $newVersion).Replace('$commit', $commit)
                    }
                } elseif ($json.url) {
                    # uBlock等の構造
                    $urlTemplate = $json.autoupdate.url
                    $json.url = $urlTemplate.Replace('$version', $newVersion).Replace('$commit', $commit)
                    $json.psobject.Properties.Remove('hash')
                }

                $json | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding Ascii
                "[$fileName] Updated: $oldVersion -> $newVersion" | Out-File $logFile -Append -Encoding UTF8
            } else {
                "[$fileName] $newVersion (Up to date)" | Out-File $logFile -Append -Encoding UTF8
            }
        }
    }
    "--------------------------------------------------" | Out-File $logFile -Append -Encoding UTF8
} catch {
    "$date - Critical Error: $_" | Out-File $logFile -Append -Encoding UTF8
}