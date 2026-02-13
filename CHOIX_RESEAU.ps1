# 1. Vérification Admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object Windows.Forms.Form
$form.Text = "Gestionnaire de Priorité Réseau (Admin)"
$form.Size = New-Object Drawing.Size(850, 580)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.TopMost = $true

# --- PANNEAU GAUCHE (ACTIONS) ---
$labelList = New-Object Windows.Forms.Label
$labelList.Text = "1. Sélectionner l'interface à forcer :"
$labelList.Location = New-Object Drawing.Point(20, 20)
$labelList.AutoSize = $true
$form.Controls.Add($labelList)

$chkAll = New-Object Windows.Forms.CheckBox
$chkAll.Text = "Afficher toutes les cartes"
$chkAll.Location = New-Object Drawing.Point(20, 45)
$chkAll.Add_Click({ Update-List })
$form.Controls.Add($chkAll)

$lb = New-Object Windows.Forms.ListBox
$lb.Location = New-Object Drawing.Point(20, 75)
$lb.Size = New-Object Drawing.Size(380, 120)
$form.Controls.Add($lb)

$chkIPv6 = New-Object Windows.Forms.CheckBox
$chkIPv6.Text = "IPv6 activé"
$chkIPv6.Location = New-Object Drawing.Point(20, 200)
$chkIPv6.AutoSize = $true
$chkIPv6.Enabled = $false
$chkIPv6.Add_Click({
    if (-not $lb.SelectedItem) { return }
    $alias = ($lb.SelectedItem -split ' \[ID:')[0]
    try {
        if ($chkIPv6.Checked) {
            Enable-NetAdapterBinding -Name $alias -ComponentID ms_tcpip6
        } else {
            Disable-NetAdapterBinding -Name $alias -ComponentID ms_tcpip6
        }
    } catch { [Windows.Forms.MessageBox]::Show("Erreur : $($_.Exception.Message)") }
})
$form.Controls.Add($chkIPv6)

$btnIPv6Info = New-Object Windows.Forms.Button
$btnIPv6Info.Text = "i"
$btnIPv6Info.Size = New-Object Drawing.Size(20, 20)
$btnIPv6Info.Location = New-Object Drawing.Point(120, 200)
$btnIPv6Info.Font = New-Object Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$btnIPv6Info.FlatStyle = "Flat"
$btnIPv6Info.Add_Click({
    [Windows.Forms.MessageBox]::Show(
        "Désactiver l'IPv6 sur une interface force Windows à utiliser uniquement l'IPv4 pour le routage sur cette carte.`n`nCela peut aider à forcer la priorité réseau car Windows utilise parfois l'IPv6 pour router le trafic, contournant les métriques IPv4.`n`nImpact :`n- Aucun impact sur la majorité des usages (web, jeux, etc.)`n- Peut empêcher certains services locaux utilisant exclusivement IPv6`n- Réversible à tout moment en recochant la case",
        "IPv6 - Information",
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Information)
})
$form.Controls.Add($btnIPv6Info)

$lb.Add_SelectedIndexChanged({
    if ($lb.SelectedItem) {
        $alias = ($lb.SelectedItem -split ' \[ID:')[0]
        $chkIPv6.Enabled = $true
        try {
            $binding = Get-NetAdapterBinding -Name $alias -ComponentID ms_tcpip6 -ErrorAction Stop
            $chkIPv6.Checked = $binding.Enabled
        } catch {
            $chkIPv6.Checked = $false
            $chkIPv6.Enabled = $false
        }
    } else {
        $chkIPv6.Enabled = $false
    }
})

$labelDiag = New-Object Windows.Forms.Label
$labelDiag.Text = "2. État actuel des routes (IPv4) :"
$labelDiag.Location = New-Object Drawing.Point(20, 225)
$labelDiag.AutoSize = $true
$form.Controls.Add($labelDiag)

$txt = New-Object Windows.Forms.TextBox
$txt.Multiline = $true
$txt.ReadOnly = $true
$txt.Location = New-Object Drawing.Point(20, 245)
$txt.Size = New-Object Drawing.Size(380, 165)
$txt.BackColor = [System.Drawing.Color]::White
$txt.Font = New-Object Drawing.Font("Consolas", 8)
$form.Controls.Add($txt)

$btnApply = New-Object Windows.Forms.Button
$btnApply.Text = "FORCER LA PRIORITÉ"
$btnApply.Location = New-Object Drawing.Point(20, 420)
$btnApply.Size = New-Object Drawing.Size(185, 45)
$btnApply.BackColor = [System.Drawing.Color]::LightGreen
$btnApply.Font = New-Object Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnApply.Add_Click({
    if ($lb.SelectedItem) {
        $id = ($lb.SelectedItem -split 'ID: ')[1].Replace(']','')
        try {
            # Forcer la métrique basse sur l'interface choisie
            Set-NetIPInterface -InterfaceIndex $id -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 10
            # Forcer la métrique de route à 0 sur l'interface choisie
            Get-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceIndex $id -AddressFamily IPv4 -ErrorAction SilentlyContinue | Set-NetRoute -RouteMetric 0
            # Forcer une métrique haute sur toutes les autres interfaces (au lieu de l'automatique)
            Get-NetIPInterface -AddressFamily IPv4 | Where { $_.InterfaceIndex -ne $id -and $_.InterfaceAlias -match "Wi-Fi|Ethernet" } | ForEach-Object {
                Set-NetIPInterface -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 1000
                Get-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Set-NetRoute -RouteMetric 1000
            }
            Update-List
            [Windows.Forms.MessageBox]::Show("Priorité appliquée avec succès !`nInterface choisie : métrique 10`nAutres interfaces : métrique 1000", "Terminé")
        } catch { [Windows.Forms.MessageBox]::Show("Erreur : $($_.Exception.Message)") }
    }
})
$form.Controls.Add($btnApply)

$btnReset = New-Object Windows.Forms.Button
$btnReset.Text = "RESET PRIORITÉS"
$btnReset.Location = New-Object Drawing.Point(215, 420)
$btnReset.Size = New-Object Drawing.Size(185, 45)
$btnReset.BackColor = [System.Drawing.Color]::LightCoral
$btnReset.Font = New-Object Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnReset.Add_Click({
    try {
        Get-NetIPInterface -AddressFamily IPv4 | Set-NetIPInterface -AutomaticMetric Enabled
        Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Set-NetRoute -RouteMetric 0
        Update-List
        [Windows.Forms.MessageBox]::Show("Toutes les interfaces sont remises en métrique automatique.`nLes métriques de route sont remises à 0.`nWindows gère à nouveau les priorités.", "Reset Terminé")
    } catch { [Windows.Forms.MessageBox]::Show("Erreur : $($_.Exception.Message)") }
})
$form.Controls.Add($btnReset)

# --- PANNEAU DROIT (PRÉREQUIS ET AIDE) ---
$grpHelp = New-Object Windows.Forms.GroupBox
$grpHelp.Text = " PRÉREQUIS & CONFIGURATION "
$grpHelp.Location = New-Object Drawing.Point(420, 20)
$grpHelp.Size = New-Object Drawing.Size(390, 460)
$form.Controls.Add($grpHelp)

$helpText = New-Object Windows.Forms.TextBox
$helpText.Location = New-Object Drawing.Point(15, 30)
$helpText.Size = New-Object Drawing.Size(360, 350)
$helpText.Multiline = $true
$helpText.ReadOnly = $true
$helpText.BackColor = [System.Drawing.SystemColors]::Control
$helpText.BorderStyle = "None"
$helpText.Font = New-Object Drawing.Font("Segoe UI", 9)
$helpText.Text = "A. ICÔNE SYSTÈME (Windows 11) :`r`nSur Windows 11, l'icône du system tray affiche toujours Ethernet tant qu'un câble est branché, même si le Wi-Fi est prioritaire. C'est normal : l'icône ne reflète pas le routage réel. Utilisez le bouton 'Tester' ci-dessous pour vérifier quelle interface est réellement utilisée.`r`n`r`nB. CRÉATION DU RACCOURCI :`r`n1. Clic-droit Bureau > Nouveau > Raccourci.`r`n2. Cible (Copiez-collez) :`r`n   powershell.exe -WindowStyle Hidden -File `"$PSCommandPath`"`r`n3. Nommez-le 'Gestionnaire Réseau'.`r`n`r`nC. PROPRIÉTÉS DU RACCOURCI :`r`n1. Clic-droit sur le raccourci > Propriétés.`r`n2. Bouton 'Avancé' > Cochez 'Exécuter en tant qu'administrateur'.`r`n`r`n---`r`nNote : Ce programme désactive la 'Métrique Automatique' pour fixer la valeur à 10 sur l'interface choisie."
$grpHelp.Controls.Add($helpText)

$btnTest = New-Object Windows.Forms.Button
$btnTest.Text = "Tester l'interface prioritaire"
$btnTest.Location = New-Object Drawing.Point(15, 385)
$btnTest.Size = New-Object Drawing.Size(360, 35)
$btnTest.BackColor = [System.Drawing.Color]::LightSkyBlue
$btnTest.Add_Click({
    $btnTest.Enabled = $false
    $btnTest.Text = "Test en cours..."
    $job = Start-Job -ScriptBlock {
        $r = Test-NetConnection -ComputerName 8.8.8.8 -WarningAction SilentlyContinue
        [PSCustomObject]@{ Alias = $r.InterfaceAlias; Source = $r.SourceAddress.IPAddress; Ping = $r.PingSucceeded }
    }
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({
        if ($job.State -ne 'Running') {
            $timer.Stop()
            $btnTest.Text = "Tester l'interface prioritaire"
            $btnTest.Enabled = $true
            try {
                $r = Receive-Job -Job $job
                Remove-Job -Job $job
                [Windows.Forms.MessageBox]::Show(
                    "Interface utilisée : $($r.Alias)`nAdresse source : $($r.Source)`nPing : $($r.Ping)",
                    "Test de connexion",
                    [Windows.Forms.MessageBoxButtons]::OK,
                    [Windows.Forms.MessageBoxIcon]::Information)
            } catch { [Windows.Forms.MessageBox]::Show("Erreur : $($_.Exception.Message)") }
        }
    }.GetNewClosure())
    $timer.Start()
})
$grpHelp.Controls.Add($btnTest)

$btnNetCpl = New-Object Windows.Forms.Button
$btnNetCpl.Text = "Ouvrir les Connexions Réseau"
$btnNetCpl.Location = New-Object Drawing.Point(15, 425)
$btnNetCpl.Size = New-Object Drawing.Size(360, 25)
$btnNetCpl.FlatStyle = "Flat"
$btnNetCpl.Add_Click({ ncpa.cpl })
$grpHelp.Controls.Add($btnNetCpl)

# --- MISE À JOUR ---
function Update-List {
    $lb.Items.Clear()
    $ints = Get-NetIPInterface -AddressFamily IPv4 
    if (-not $chkAll.Checked) { $ints = $ints | Where { $_.InterfaceAlias -match "Wi-Fi|Ethernet" } }
    foreach ($i in $ints) { [void]$lb.Items.Add("$($i.InterfaceAlias) [ID: $($i.InterfaceIndex)]") }
    
    $routes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4
    $txt.Text = "ROUTES DÉTECTÉES :`r`n---------------------------`r`n"
    foreach ($r in $routes) {
        $iface = Get-NetIPInterface -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4 | Select -First 1
        $alias = $iface.InterfaceAlias
        $ifMetric = $iface.InterfaceMetric
        $totalMetric = $r.RouteMetric + $ifMetric
        $txt.Text += "-> $alias`r`n   Interface: $ifMetric + Route: $($r.RouteMetric) = Total: $totalMetric`r`n"
    }
}

Update-List
$form.ShowDialog()