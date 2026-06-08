param(
    [int]$MaxRetries = 3,
    [int]$DelaySeconds = 30
)

for ($i = 1; $i -le $MaxRetries; $i++) {
    try {
        Install-Module BcContainerHelper -Force -AllowClobber -ErrorAction Stop
        Import-Module BcContainerHelper -Force -DisableNameChecking
        return
    }
    catch {
        if ($i -eq $MaxRetries) { throw }
        Write-Host "Install-Module failed (attempt $i/$MaxRetries): $_"
        Start-Sleep -Seconds $DelaySeconds
    }
}
