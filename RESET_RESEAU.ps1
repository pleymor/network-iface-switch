# Vérification Admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

Add-Type -AssemblyName System.Windows.Forms

$corePath = Join-Path $PSScriptRoot 'NetIfaceSwitch.Core.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    [Windows.Forms.MessageBox]::Show("Fichier manquant : $corePath`n`nGardez NetIfaceSwitch.Core.ps1 dans le même dossier que RESET_RESEAU.ps1.", "Erreur") | Out-Null
    Exit 1
}
. $corePath

# Action : on remet TOUT en automatique (IPv4 et IPv6), routes par défaut à 0, et on oublie l'ordre de la vue Simple.
# En cas d'erreur, les modifications déjà faites sont annulées.
try {
    $states = @(Get-NisInterfaceStates -IncludeVirtual)
    $desired = @(Get-NisResetDesired -States $states)
    $changes = @(Get-NisChangeSet -Desired $desired -States $states)
    $result = Invoke-NisChangeSet -Actions $changes
    if ($result.Success) {
        Clear-NisOrder
        [Windows.Forms.MessageBox]::Show("Toutes les interfaces ont été remises en mode 'Métrique Automatique' ($($result.AppliedCount) modification(s)).`nLes métriques de route sont remises à 0.`nL'ordre sauvegardé de la vue Simple est oublié.`nWindows gère à nouveau les priorités.", "Reset Terminé") | Out-Null
    } else {
        $report = @(Format-NisResultReport -Result $result) -join "`n"
        [Windows.Forms.MessageBox]::Show("Erreur lors de la réinitialisation : $($result.ErrorMessage)`nLes modifications déjà faites ont été annulées.`n`n$report", "Reset - échec") | Out-Null
    }
} catch {
    [Windows.Forms.MessageBox]::Show("Erreur lors de la réinitialisation : $($_.Exception.Message)") | Out-Null
}
