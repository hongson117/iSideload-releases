$ErrorActionPreference = 'Stop'
try {
    $expectedNames = @('isl-cli.exe', 'iSideload.ipa', 'Cai-iSideload.bat', 'Kiem-tra-goi.ps1', 'HUONG-DAN.md', 'ThirdPartyNotices.txt')
    $seenNames = @{}
    foreach ($line in [IO.File]::ReadAllLines([IO.Path]::Combine($PSScriptRoot, 'SHA256SUMS.txt'))) {
        if ($line -notmatch '^([0-9a-fA-F]{64})  ([A-Za-z0-9_.-]+)$') { throw 'Invalid checksum manifest.' }
        $expectedHash = $Matches[1]
        $fileName = $Matches[2]
        if (($expectedNames -notcontains $fileName) -or $seenNames.ContainsKey($fileName)) { throw 'Unexpected or duplicate file in checksum manifest.' }
        $seenNames[$fileName] = $true
        $algorithm = [Security.Cryptography.SHA256]::Create()
        $stream = [IO.File]::OpenRead([IO.Path]::Combine($PSScriptRoot, $fileName))
        try {
            $actual = [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '')
        } finally {
            $stream.Dispose()
            $algorithm.Dispose()
        }
        if ($actual -ne $expectedHash) { throw "Checksum mismatch: $fileName" }
    }
    if ($seenNames.Count -ne $expectedNames.Count) { throw 'Incomplete checksum manifest.' }
    Write-Host 'Package checksums OK.'
    exit 0
} catch {
    Write-Host ('LOI: ' + $_.Exception.Message)
    exit 1
}
