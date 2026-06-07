# scripts/update-fbneo.ps1
# FinalBurn Neo (Nightly) 専用 マニフェスト更新スクリプト
# URLは latest タグ固定のため、version(コミットハッシュ)の更新と hash の除去のみ行う。

$ProgressPreference = 'SilentlyContinue'

if ($env:GITHUB_WORKSPACE) {
    $bucketPath     = "$env:GITHUB_WORKSPACE\bucket"
    $checkverScript = "$env:USERPROFILE\scoop\apps\scoop\current\bin\checkver.ps1"
} else {
    $bucketPath     = "$env:SCOOP\buckets\my-bucket"
    $checkverScript = "$env:SCOOP\apps\scoop\current\bin\checkver.ps1"
}

$jsonPath = "$bucketPath\fbneo-nightly.json"
$logFile  = "$bucketPath\update_log.txt"
$date     = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName = Split-Path $jsonPath -Leaf

try {
    "$date - [FBNeo] Update Check Started" | Out-File $logFile -Append -Encoding UTF8

    $checkOutput = & $checkverScript $jsonPath -NoColors *>&1 | Out-String

    if ($checkOutput -match '(?m)^\s*[\w-]+:\s+([^\s\r\n]+)') {
        $newVersion = $matches[1]
        $json       = Get-Content $jsonPath -Raw | ConvertFrom-Json
        $oldVersion = $json.version

        if ($newVersion -ne $oldVersion) {
            $json.version = $newVersion

            # URLは固定。hashプロパティがあれば除去（このマニフェストには元々無いが念のため）
            foreach ($arch in '64bit', '32bit') {
                if ($json.architecture.$arch) {
                    $json.architecture.$arch.psobject.Properties.Remove('hash')
                }
            }

            $json | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding Ascii
            "[$fileName] Updated: $oldVersion -> $newVersion" | Out-File $logFile -Append -Encoding UTF8
        } else {
            "[$fileName] $newVersion (Up to date)" | Out-File $logFile -Append -Encoding UTF8
        }
    } else {
        "[$fileName] WARNING: could not parse checkver output" | Out-File $logFile -Append -Encoding UTF8
    }

    "--------------------------------------------------" | Out-File $logFile -Append -Encoding UTF8
} catch {
    "$date - [FBNeo] Critical Error: $_" | Out-File $logFile -Append -Encoding UTF8
}
