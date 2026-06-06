# --------------------------------------------------------
# GitHub Actions環境かローカルPC環境かを自動判定
if ($env:GITHUB_WORKSPACE) {
    $bucketPath     = "$env:GITHUB_WORKSPACE\bucket"
    $checkverScript = "$env:USERPROFILE\scoop\apps\scoop\current\bin\checkver.ps1"
} else {
    $bucketPath     = ".\bucket"
    $checkverScript = "$env:SCOOP\apps\scoop\current\bin\checkver.ps1"
}

$logFile = "$bucketPath\update_log.txt"
$date    = Get-Date -Format "yyyy/MM/dd HH:mm:ss"

# プログレスバー非表示
$ProgressPreference = 'SilentlyContinue'

# --------------------------------------------------------
# URLテンプレートにプレースホルダを適用する共通関数
#   $version  : 検出された新バージョン全体
#   $commit   : バージョン末尾の "16進数" 部分（ドット区切りの末尾、なければ全体）
#   $captures : checkver の追加キャプチャ（$matchVersion / $matchDate 等）
# --------------------------------------------------------
function Expand-UrlTemplate {
    param(
        [string]$template,
        [string]$version,
        [string]$commit,
        [hashtable]$captures
    )

    if ([string]::IsNullOrEmpty($template)) { return $template }

    $result = $template

    # 1) 名前付き/番号付きキャプチャを先に置換（長い名前から処理して部分一致を防ぐ）
    if ($captures) {
        foreach ($key in ($captures.Keys | Sort-Object { $_.Length } -Descending)) {
            $result = $result.Replace('$' + $key, [string]$captures[$key])
        }
    }

    # 2) $version / $commit を置換
    $result = $result.Replace('$version', $version).Replace('$commit', $commit)

    return $result
}

# --------------------------------------------------------
# 生のJSONテキストに対して "キー": "値" を正規表現で書き換える共通関数
#   ConvertTo-Json を使わないことで元のインデントを完全保持する。
#   $node はドット区切りのキー位置を示すための情報ではなく、
#   ここでは「最後に出現する該当キー」ではなく文脈を限定して置換する。
# ※ url/extract_dir/version はマニフェスト内でキー名が一意か、
#   architecture配下で重複しても値の文字列が異なるため、値ベースで安全に置換する。
# --------------------------------------------------------
function Set-JsonStringValue {
    param(
        [string]$text,
        [string]$key,
        [string]$oldValue,
        [string]$newValue
    )

    if ([string]::IsNullOrEmpty($oldValue)) { return $text }
    if ($oldValue -eq $newValue)            { return $text }

    # 旧値をリテラルとしてエスケープして検索（JSON内のエスケープを考慮し \\ と \/ は素直に扱う）
    $escapedOld = [regex]::Escape($oldValue)
    # "key": "oldValue" の形にマッチさせ、値部分だけ置換
    $pattern = '("' + [regex]::Escape($key) + '"\s*:\s*")' + $escapedOld + '(")'
    $replacement = '${1}' + $newValue.Replace('$', '$$$$') + '${2}'

    return [regex]::Replace($text, $pattern, $replacement)
}

try {
    $targetManifests = Get-ChildItem "$bucketPath\*.json"

    "$date - Update Check Started" | Out-File $logFile -Append -Encoding UTF8

    foreach ($file in $targetManifests) {
        $jsonPath = $file.FullName
        $fileName = $file.Name

        $checkOutput = & $checkverScript $jsonPath -NoColors *>&1 | Out-String

        if ($checkOutput -match '(?m)^\s*[\w.-]+:\s+([^\s\r\n]+)') {
            $newVersion = $matches[1]

            # 比較用に現行 version を取得（オブジェクトは比較にのみ使用、書き込みには使わない）
            $json       = Get-Content $jsonPath -Raw | ConvertFrom-Json
            $oldVersion = $json.version

            if ($newVersion -eq $oldVersion) {
                "[$fileName] $newVersion (Up to date)" | Out-File $logFile -Append -Encoding UTF8
                continue
            }

            # ---- $commit プレースホルダ（"数字.hash" 形式の末尾、なければ全体）----
            $commit = if ($newVersion -match '\.([0-9a-f]+)$') { $matches[1] } else { $newVersion }

            # ---- 追加キャプチャ（autoupdate_capture があれば適用）----------------
            $captures = @{}
            if ($json.autoupdate -and $json.autoupdate.autoupdate_capture) {
                $capRegex = [string]$json.autoupdate.autoupdate_capture
                $m = [regex]::Match($newVersion, $capRegex)
                if ($m.Success) {
                    foreach ($gname in ([regex]$capRegex).GetGroupNames()) {
                        if ($gname -match '^\d+$') {
                            if ([int]$gname -gt 0 -and $m.Groups[$gname].Success) {
                                $captures["match$gname"] = $m.Groups[$gname].Value
                            }
                        } else {
                            if ($m.Groups[$gname].Success) {
                                $captures["match$gname"] = $m.Groups[$gname].Value
                            }
                        }
                    }
                } else {
                    "[$fileName] WARNING: autoupdate_capture did not match '$newVersion'" | Out-File $logFile -Append -Encoding UTF8
                }
            }

            # ---- 旧→新の置換対象ペアを収集（生テキスト置換用）--------------------
            # version は必ず置換。url / extract_dir は autoupdate テンプレートから新値を生成。
            $replacements = New-Object System.Collections.Generic.List[object]

            # version 本体
            $replacements.Add([pscustomobject]@{ Key = 'version'; Old = $oldVersion; New = $newVersion })

            # --- url / extract_dir の旧値・新値を算出する内部関数 ---
            function Add-NodeReplacements {
                param($node, $autoupdateNode)

                if (-not $autoupdateNode) { return }

                if ($autoupdateNode.url -and $node.url) {
                    $newUrl = Expand-UrlTemplate -template $autoupdateNode.url -version $newVersion -commit $commit -captures $captures
                    $script:replacements.Add([pscustomobject]@{ Key = 'url'; Old = $node.url; New = $newUrl })
                }
                if ($autoupdateNode.extract_dir -and $node.extract_dir) {
                    $newDir = Expand-UrlTemplate -template $autoupdateNode.extract_dir -version $newVersion -commit $commit -captures $captures
                    if ($node.extract_dir -ne $newDir) {
                        $script:replacements.Add([pscustomobject]@{ Key = 'extract_dir'; Old = $node.extract_dir; New = $newDir })
                    }
                }
            }

            if ($json.architecture.'64bit'.url) {
                Add-NodeReplacements -node $json.architecture.'64bit' -autoupdateNode $json.autoupdate.architecture.'64bit'
                if ($json.architecture.'32bit'.url) {
                    Add-NodeReplacements -node $json.architecture.'32bit' -autoupdateNode $json.autoupdate.architecture.'32bit'
                }
            } elseif ($json.url) {
                Add-NodeReplacements -node $json -autoupdateNode $json.autoupdate
            }

            # ---- 生テキストに対して順次置換（インデント保持）--------------------
            $rawText = Get-Content $jsonPath -Raw

            foreach ($r in $replacements) {
                $rawText = Set-JsonStringValue -text $rawText -key $r.Key -oldValue $r.Old -newValue $r.New
            }

            # 末尾改行を保ったまま書き込み（BOMなしUTF-8推奨。ASCIIだと非ASCII文字が壊れるため変更）
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($jsonPath, $rawText, $utf8NoBom)

            "[$fileName] Updated: $oldVersion -> $newVersion" | Out-File $logFile -Append -Encoding UTF8
        }
    }
    "--------------------------------------------------" | Out-File $logFile -Append -Encoding UTF8
} catch {
    "$date - Critical Error: $_" | Out-File $logFile -Append -Encoding UTF8
}
