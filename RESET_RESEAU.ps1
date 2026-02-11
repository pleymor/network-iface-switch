# Vérification Admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

Add-Type -AssemblyName System.Windows.Forms

# Action : On remet TOUT en automatique pour l'IPv4
try {
    Get-NetIPInterface -AddressFamily IPv4 | Set-NetIPInterface -AutomaticMetric Enabled
    [Windows.Forms.MessageBox]::Show("Toutes les interfaces ont été remises en mode 'Métrique Automatique'. Windows gère à nouveau les priorités.", "Reset Terminé")
} catch {
    [Windows.Forms.MessageBox]::Show("Erreur lors de la réinitialisation : $($_.Exception.Message)")
}