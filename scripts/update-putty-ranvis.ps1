# scripts/update-putty-ranvis.ps1
# PuTTY-ranvis 専用 ミラーリング＆マニフェスト更新スクリプト
#
# ranvis サイトはブラウザ以外のUAからのDLを拒否するため、
# (1) ブラウザ偽装UAでzip/7zを取得し、
# (2) 自分のGitHubリリース(固定タグ)へアップロードしてミラーし、
# (3) マニフェストのURLをGitHubミラー(固定URL)に向ける。
#
# 必要環境変数:
#   GH_REPO       : ミラー先リポジトリ "owner/repo" (例: "yourname/scoop-bucket")
#   GITHUB_TOKEN  : gh CLI 用トークン (Actionsが自動で渡す)
# 前提: gh CLI が利用可能であること (GitHub Actions runnerには標準搭載)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---- 設定 ----------------------------------------------------------
$mirrorTag  = 'putty-ranvis-latest'   # ミラー用の固定リリースタグ
$browserUA  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
$ghRepo     = $env:GH_REPO

if ($env:GITHUB_WORKSPACE) {
    $bucketPath = "$env:GITHUB_WORKSPACE\bucket"
} else {
    $bucketPath = "$env:SCOOP\buckets\my-bucket"
}

$jsonPath = "$bucketPath\putty-ranvis.json"
$logFile  = "$bucketPath\update_log.txt"
$date     = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName = Split-Path $jsonPath -Leaf
$workDir  = Join-Path ([System.IO.Path]::GetTempPath()) "putty-ranvis-mirror"

function Write-Log($msg) { "$msg" | Out-File $logFile -Append -Encoding UTF8 }

try {
    Write-Log "$date - [PuTTY-ranvis] Mirror & Update Started"

    if (-not $ghRepo) { throw "Environment variable GH_REPO is not set." }

    # ---- 1) サイトから最新版情報を取得 -----------------------------
    $pageUrl  = 'https://www.ranvis.com/putty'
    $html     = (Invoke-WebRequest -Uri $pageUrl -UserAgent $browserUA -UseBasicParsing).Content

    # 最新の 64bit(.7z) / 32bit(.zip) を1件ずつ拾う（ページ先頭=最新）
    $m64 = [regex]::Match($html, 'PuTTY-(?<ver>[\d.]+)-ranvis-(?<date>\d{8})\.win64\.7z')
    $m32 = [regex]::Match($html, 'PuTTY-(?<ver>[\d.]+)-ranvis-(?<date>\d{8})\.win32\.zip')
    if (-not $m64.Success) { throw "Could not find win64 .7z link on the page." }

    $ver         = $m64.Groups['ver'].Value
    $dateStamp   = $m64.Groups['date'].Value
    $newVersion  = "$ver.$dateStamp"          # 複合バージョン (例: 0.84.20260524)

    $json        = Get-Content $jsonPath -Raw | ConvertFrom-Json
    $oldVersion  = $json.version

    if ($newVersion -eq $oldVersion) {
        Write-Log "[$fileName] $newVersion (Up to date)"
        Write-Log "--------------------------------------------------"
        return
    }

    Write-Log "[$fileName] New version detected: $oldVersion -> $newVersion"

    # ---- 2) zip/7z を取得 -----------------------------------------
    if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
    New-Item -ItemType Directory -Path $workDir | Out-Null

    $srcBase = 'https://www.ranvis.com/downloads'

    $assets = @()  # ミラーするファイルのリスト

    # 64bit (.7z)
    $name64 = "PuTTY-$ver-ranvis-$dateStamp.win64.7z"
    $path64 = Join-Path $workDir $name64
    Invoke-WebRequest -Uri "$srcBase/$name64" -UserAgent $browserUA -OutFile $path64 -UseBasicParsing
    $assets += $path64

    # 32bit (.zip) ※見つかった場合のみ
    if ($m32.Success) {
        $ver32  = $m32.Groups['ver'].Value
        $date32 = $m32.Groups['date'].Value
        $name32 = "PuTTY-$ver32-ranvis-$date32.win32.zip"
        $path32 = Join-Path $workDir $name32
        Invoke-WebRequest -Uri "$srcBase/$name32" -UserAgent $browserUA -OutFile $path32 -UseBasicParsing
        $assets += $path32
    }

    # ---- 3) GitHubリリース(固定タグ)へミラー -----------------------
    # リリースが無ければ作成、あれば再利用。--clobber で同名アセットを上書き。
    $relExists = (& gh release view $mirrorTag --repo $ghRepo *>&1; $LASTEXITCODE -eq 0)
    if (-not $relExists) {
        & gh release create $mirrorTag --repo $ghRepo `
            --title "PuTTY-ranvis mirror" `
            --notes "Auto-mirrored from https://www.ranvis.com/putty (User-Agent workaround for Scoop)."
        if ($LASTEXITCODE -ne 0) { throw "gh release create failed." }
    }

    & gh release upload $mirrorTag @assets --repo $ghRepo --clobber
    if ($LASTEXITCODE -ne 0) { throw "gh release upload failed." }

    Write-Log "[$fileName] Mirrored assets to $ghRepo (tag: $mirrorTag)"

    # ---- 4) マニフェスト更新 --------------------------------------
    # ミラー先の固定ダウンロードURL (/releases/latest/download/ ではなく
    # 明示タグURLを使い、アセット名にバージョンを含めることでScoopに更新を認識させる)
    $mirrorBase = "https://github.com/$ghRepo/releases/download/$mirrorTag"

    $json.version = $newVersion
    $json.architecture.'64bit'.url = "$mirrorBase/$name64"
    $json.architecture.'64bit'.psobject.Properties.Remove('hash')
    if ($m32.Success) {
        $json.architecture.'32bit'.url = "$mirrorBase/$name32"
        $json.architecture.'32bit'.psobject.Properties.Remove('hash')
    }

    $json | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding Ascii
    Write-Log "[$fileName] Updated: $oldVersion -> $newVersion"
    Write-Log "--------------------------------------------------"
} catch {
    Write-Log "$date - [PuTTY-ranvis] Critical Error: $_"
    exit 1
} finally {
    if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue }
}
