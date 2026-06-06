# --------------------------------------------------------
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

# --------------------------------------------------------
# URLテンプレートにプレースホルダを適用する共通関数
#   $version : 検出された新バージョン全体
#   $commit  : バージョン末尾の "16進数" 部分（従来仕様）
#   $captures: checkver の追加キャプチャ（$matchN / 名前付き）を格納したハッシュテーブル
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

    # 1) 名前付き / 番号付きキャプチャを先に置換（長い名前から処理して部分一致を防ぐ）
    if ($captures) {
        foreach ($key in ($captures.Keys | Sort-Object { $_.Length } -Descending)) {
            $result = $result.Replace('$' + $key, [string]$captures[$key])
        }
    }

    # 2) 従来の $version / $commit を置換
    $result = $result.Replace('$version', $version).Replace('$commit', $commit)

    return $result
}

# --------------------------------------------------------
# architecture配下 / トップレベルの url・extract_dir を更新する共通関数
#   $node         : 更新対象ノード（$json.architecture.'64bit' か $json 自体）
#   $autoupdateNode : 対応するautoupdateノード
# --------------------------------------------------------
function Update-Node {
    param(
        $node,
        $autoupdateNode,
        [string]$version,
        [string]$commit,
        [hashtable]$captures
    )

    if (-not $autoupdateNode) { return }

    if ($autoupdateNode.url) {
        $node.url = Expand-UrlTemplate -template $autoupdateNode.url -version $version -commit $commit -captures $captures
        $node.psobject.Properties.Remove('hash')
    }

    if ($autoupdateNode.extract_dir) {
        $node.extract_dir = Expand-UrlTemplate -template $autoupdateNode.extract_dir -version $version -commit $commit -captures $captures
    }
}

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

                # ---- 従来の $commit プレースホルダ用（"timestamp.hash" 形式に対応）----
                $commit = if ($newVersion -match '\.([0-9a-f]+)$') { $matches[1] } else { $newVersion }

                # ---- 追加キャプチャの取得 -------------------------------------------
                # マニフェストに "autoupdate_capture" が定義されていれば、
                # その正規表現を $newVersion に適用し、名前付き/番号付きグループを
                # プレースホルダ（例: $matchVersion, $matchDate, $match1 ...）として展開する。
                $captures = @{}
                if ($json.autoupdate -and $json.autoupdate.autoupdate_capture) {
                    $capRegex = [string]$json.autoupdate.autoupdate_capture
                    $m = [regex]::Match($newVersion, $capRegex)
                    if ($m.Success) {
                        # 名前付きグループ → $match<Name>
                        foreach ($gname in ([regex]$capRegex).GetGroupNames()) {
                            if ($gname -match '^\d+$') {
                                # 番号グループ（0は全体なので除外）
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

                # ---- URL等の更新処理（architectureあり/なし両対応）-----------------
                if ($json.architecture.'64bit'.url) {
                    # 64bit があるケース（エミュレータ等）
                    Update-Node -node $json.architecture.'64bit' `
                                -autoupdateNode $json.autoupdate.architecture.'64bit' `
                                -version $newVersion -commit $commit -captures $captures

                    # 32bit も定義されていれば更新（PuTTY-ranvis等）
                    if ($json.architecture.'32bit'.url) {
                        Update-Node -node $json.architecture.'32bit' `
                                    -autoupdateNode $json.autoupdate.architecture.'32bit' `
                                    -version $newVersion -commit $commit -captures $captures
                    }
                } elseif ($json.url) {
                    # トップレベルurlのみのケース（uBlock等）
                    Update-Node -node $json `
                                -autoupdateNode $json.autoupdate `
                                -version $newVersion -commit $commit -captures $captures
                }

                # ---- 保存用に autoupdate_capture を除去（Scoop標準スキーマ外のため）----
                if ($json.autoupdate -and $json.autoupdate.psobject.Properties['autoupdate_capture']) {
                    # ※残しても害はないが、Scoop公式の検証に通したい場合は除去する。
                    #   再更新時に必要なので、ここではコメントアウトして残す方針とする。
                    # $json.autoupdate.psobject.Properties.Remove('autoupdate_capture')
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
