param(
    [int]$MaxRetries = 3,
    [int]$DelaySeconds = 30
)

Write-Host "::group::Environment diagnostics"
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host "OS: $($PSVersionTable.OS)"
Write-Host "TLS protocols (before): $([Net.ServicePointManager]::SecurityProtocol)"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "TLS protocols (after): $([Net.ServicePointManager]::SecurityProtocol)"

Write-Host "`nPackage sources:"
Get-PackageSource | Format-Table Name, Location, IsTrusted, ProviderName -AutoSize | Out-String | Write-Host

Write-Host "PS repositories (before):"
Get-PSRepository | Format-Table Name, SourceLocation, InstallationPolicy -AutoSize | Out-String | Write-Host

$gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
if (-not $gallery) {
    Write-Host "PSGallery not registered — registering explicitly"
    Register-PSRepository -Default -ErrorAction SilentlyContinue
    $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $gallery) {
        Write-Host "Register-PSRepository -Default failed, registering with explicit URL"
        Register-PSRepository -Name PSGallery `
            -SourceLocation 'https://www.powershellgallery.com/api/v2' `
            -InstallationPolicy Trusted
    }
    else {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
}
elseif ($gallery.InstallationPolicy -ne 'Trusted') {
    Write-Host "PSGallery found but not trusted — setting to Trusted"
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}
else {
    Write-Host "PSGallery is registered and trusted"
}

Write-Host "`nPS repositories (after):"
Get-PSRepository | Format-Table Name, SourceLocation, InstallationPolicy -AutoSize | Out-String | Write-Host

Write-Host "`nSearching for BcContainerHelper on PSGallery..."
$found = Find-Module BcContainerHelper -Repository PSGallery -ErrorAction SilentlyContinue
if ($found) {
    Write-Host "Found BcContainerHelper v$($found.Version) (published $($found.PublishedDate))"
}
else {
    Write-Host "::warning::Find-Module returned no results for BcContainerHelper"
}
Write-Host "::endgroup::"

for ($i = 1; $i -le $MaxRetries; $i++) {
    try {
        Write-Host "Installing BcContainerHelper (attempt $i/$MaxRetries)..."
        Install-Module BcContainerHelper -Force -AllowClobber -ErrorAction Stop
        $mod = Get-Module BcContainerHelper -ListAvailable | Select-Object -First 1
        Write-Host "Installed BcContainerHelper v$($mod.Version) at $($mod.ModuleBase)"

        Import-Module BcContainerHelper -Force -DisableNameChecking
        Write-Host "BcContainerHelper imported successfully"
        return
    }
    catch {
        Write-Host "::warning::Install-Module failed (attempt $i/$MaxRetries): $_"
        if ($i -lt $MaxRetries) {
            Write-Host "Exception type: $($_.Exception.GetType().FullName)"
            Write-Host "Retrying in $DelaySeconds seconds..."
            Start-Sleep -Seconds $DelaySeconds
        }
        else {
            Write-Host "::error::All $MaxRetries attempts failed"
            throw
        }
    }
}
