# Vérification Admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

Add-Type -AssemblyName System.Windows.Forms

# Action : On remet TOUT en automatique pour l'IPv4
try {
    Get-NetIPInterface -AddressFamily IPv4 | Set-NetIPInterface -AutomaticMetric Enabled
    Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Set-NetRoute -RouteMetric 0
    [Windows.Forms.MessageBox]::Show("Toutes les interfaces ont été remises en mode 'Métrique Automatique'.`nLes métriques de route sont remises à 0.`nWindows gère à nouveau les priorités.", "Reset Terminé")
} catch {
    [Windows.Forms.MessageBox]::Show("Erreur lors de la réinitialisation : $($_.Exception.Message)")
}