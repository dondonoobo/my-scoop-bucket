# scripts/update-eden.ps1
# Eden Nightly 専用 マニフェスト更新スクリプト
# version は "timestamp.hash" 形式。URL に $version 全体と末尾の $commit(hash) を使用する。

$ProgressPreference = 'SilentlyContinue'

if ($env:GITHUB_WORKSPACE) {
    $bucketPath     = "$env:GITHUB_WORKSPACE\bucket"
    $checkverScript = "$env:USERPROFILE\scoop\apps\scoop\current\bin\checkver.ps1"
} else {
    $bucketPath     = "$env:SCOOP\buckets\my-bucket"
    $checkverScript = "$env:SCOOP\apps\scoop\current\bin\checkver.ps1"
}

$jsonPath = "$bucketPath\eden-nightly.json"
$logFile  = "$bucketPath\update_log.txt"
$date     = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName = Split-Path $jsonPath -Leaf

try {
    "$date - [Eden] Update Check Started" | Out-File $logFile -Append -Encoding UTF8

    $checkOutput = & $checkverScript $jsonPath -NoColors *>&1 | Out-String

    if ($checkOutput -match '(?m)^\s*[\w-]+:\s+([^\s\r\n]+)') {
        $newVersion = $matches[1]
        $json       = Get-Content $jsonPath -Raw | ConvertFrom-Json
        $oldVersion = $json.version

        if ($newVersion -ne $oldVersion) {
            $json.version = $newVersion

            # version 末尾の 16進ハッシュ部分を $commit として抽出
            $commit = if ($newVersion -match '\.([0-9a-f]+)$') { $matches[1] } else { $newVersion }

            $urlTemplate = $json.autoupdate.architecture.'64bit'.url
            $newUrl = $urlTemplate.Replace('$version', $newVersion).Replace('$commit', $commit)
            $json.architecture.'64bit'.url = $newUrl
            $json.architecture.'64bit'.psobject.Properties.Remove('hash')

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
    "$date - [Eden] Critical Error: $_" | Out-File $logFile -Append -Encoding UTF8
}
