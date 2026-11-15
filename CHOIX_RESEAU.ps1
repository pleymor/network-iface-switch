# Gestionnaire de Priorité Réseau
#   -Vue Simple|Avance : onglet affiché au démarrage (Simple par défaut)
#   -Apercu            : lecture seule, sans élévation (boutons de modification désactivés)
param(
    [ValidateSet('Simple', 'Avance')][string]$Vue = 'Simple',
    [switch]$Apercu
)

# 1. Vérification Admin
if (-not $Apercu -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Vue $Vue" -Verb RunAs
    Exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$corePath = Join-Path $PSScriptRoot 'NetIfaceSwitch.Core.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    [Windows.Forms.MessageBox]::Show("Fichier manquant : $corePath`n`nGardez NetIfaceSwitch.Core.ps1 dans le même dossier que CHOIX_RESEAU.ps1.", "Erreur") | Out-Null
    Exit 1
}
. $corePath

$fontBold = New-Object Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$fontInfo = New-Object Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)

$form = New-Object Windows.Forms.Form
$form.Text = "Gestionnaire de Priorité Réseau (Admin)"
if ($Apercu) { $form.Text = "Gestionnaire de Priorité Réseau (aperçu - lecture seule)" }
$form.ClientSize = New-Object Drawing.Size(1000, 640)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.TopMost = $true
$form.Font = New-Object Drawing.Font("Segoe UI", 9)

# ---------------------------------------------------------------------------
# Outils communs : journal, messages, application avec confirmation
# ---------------------------------------------------------------------------

$grpLog = New-Object Windows.Forms.GroupBox
$grpLog.Text = " Journal "
$grpLog.Location = New-Object Drawing.Point(10, 515)
$grpLog.Size = New-Object Drawing.Size(980, 118)
$form.Controls.Add($grpLog)

$txtLog = New-Object Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.Location = New-Object Drawing.Point(10, 20)
$txtLog.Size = New-Object Drawing.Size(960, 90)
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.Font = New-Object Drawing.Font("Consolas", 8)
$txtLog.AccessibleName = "Journal des actions"
$grpLog.Controls.Add($txtLog)

function Write-UiLog {
    param([string]$Message)
    $txtLog.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Message`r`n")
}

function Show-Msg {
    param([string]$Text, [string]$Title = "Gestionnaire de Priorité Réseau", [string]$Icon = 'Information')
    [void][Windows.Forms.MessageBox]::Show($form, $Text, $Title, [Windows.Forms.MessageBoxButtons]::OK, [Enum]::Parse([Windows.Forms.MessageBoxIcon], $Icon))
}

function Confirm-Msg {
    param([string]$Text, [string]$Title)
    $r = [Windows.Forms.MessageBox]::Show($form, $Text, $Title, [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question, [Windows.Forms.MessageBoxDefaultButton]::Button2)
    return ($r -eq [Windows.Forms.DialogResult]::Yes)
}

function Get-UiStates {
    param([switch]$IncludeVirtual)
    try {
        # la virgule empêche PowerShell de transformer une liste vide en $null (réservé aux erreurs)
        return ,@(Get-NisInterfaceStates -IncludeVirtual:$IncludeVirtual)
    } catch {
        Write-UiLog "Lecture des interfaces impossible : $($_.Exception.Message)"
        Show-Msg "Lecture des interfaces impossible :`n$($_.Exception.Message)" "Erreur" Error
        return $null
    }
}

function Invoke-UiChange {
    <#
      Valide TOUS les réglages, affiche les modifications, demande confirmation, applique.
      En cas d'erreur, Invoke-NisChangeSet annule ce qui a déjà été fait.
    #>
    param([object[]]$Desired, [object[]]$CurrentStates, [string]$Title, [string]$Summary)
    $errs = @(Test-NisDesiredSettings -Desired $Desired -States $CurrentStates)
    if ($errs.Count -gt 0) {
        Write-UiLog "$Title : valeurs invalides, rien n'a été modifié."
        foreach ($e in $errs) { Write-UiLog "  - $e" }
        Show-Msg ("Aucune modification n'a été faite. Corrigez :`n`n- " + ($errs -join "`n- ")) "$Title - valeurs invalides" Warning
        return $null
    }
    $changeList = @(Get-NisChangeSet -Desired $Desired -States $CurrentStates)
    if ($changeList.Count -eq 0) {
        Write-UiLog "$Title : rien à modifier, la configuration est déjà en place."
        return [pscustomobject]@{ Success = $true; AppliedCount = 0; NoChange = $true }
    }
    $lines = @($changeList | Select-Object -First 25 | ForEach-Object { '- ' + (Format-NisAction -Action $_) })
    if ($changeList.Count -gt 25) { $lines += "... et $($changeList.Count - 25) autre(s)" }
    $text = ""
    if ($Summary) { $text = "$Summary`n`n" }
    $text += "Modifications à appliquer ($($changeList.Count)) :`n" + ($lines -join "`n") + "`n`nEn cas d'erreur, tout ce qui a déjà été modifié est annulé.`nContinuer ?"
    if (-not (Confirm-Msg $text $Title)) {
        Write-UiLog "$Title : annulé par l'utilisateur."
        return $null
    }
    Write-UiLog "$Title : application de $($changeList.Count) modification(s)..."
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try {
        $result = Invoke-NisChangeSet -Actions $changeList -Log { param($m) Write-UiLog "  $m" }
    } finally {
        $form.Cursor = [Windows.Forms.Cursors]::Default
    }
    $report = @(Format-NisResultReport -Result $result)
    if ($result.Success) {
        Write-UiLog "$Title : terminé ($($result.AppliedCount) modification(s))."
    } else {
        Write-UiLog "$Title : ÉCHEC - $($result.ErrorMessage)"
        foreach ($l in $report) { Write-UiLog "  $l" }
        $head = "L'application a échoué. Les modifications déjà faites ont été annulées."
        if (@($result.RollbackErrors).Count -gt 0) { $head = "L'application a échoué ET certaines annulations ont échoué : vérifiez les interfaces signalées (ou utilisez Réinitialiser)." }
        Show-Msg ("$head`n`n" + ($report -join "`n")) "$Title - échec" Error
    }
    return $result
}

function Format-StatusText {
    param($Entry)
    if (-not $Entry.Present) { return 'Absente' }
    switch ($Entry.State.Status) {
        'Up' { return 'Connectée' }
        'Disconnected' { return 'Déconnectée' }
        'Disabled' { return 'Désactivée' }
        default { return [string]$Entry.State.Status }
    }
}

function Format-CurrentMetric {
    param($State)
    if (-not $State) { return '-' }
    $auto = ''
    if ($State.AutomaticMetric) { $auto = ' (auto)' }
    if ($null -ne $State.EffectiveMetric) {
        return "$($State.InterfaceMetric)$auto + $($State.RouteMetric) = $($State.EffectiveMetric)"
    }
    return "$($State.InterfaceMetric)$auto, pas de route"
}

function Get-EffectiveSummary {
    <# Ordre effectif réel + interface choisie par Windows pour Internet (calcul local, sans ping). #>
    param([object[]]$AllStates, $ExpectedFirst)
    $order = @(Get-NisEffectiveOrder -States $AllStates)
    $parts = @()
    $n = 0
    foreach ($s in $order) { $n++; $parts += "$n. $($s.Alias) ($($s.EffectiveMetric))" }
    $text = "Ordre effectif (interfaces avec route par défaut, métrique totale) : "
    if ($parts.Count -gt 0) { $text += ($parts -join '  >  ') } else { $text += "aucune route par défaut" }
    try {
        $route = Find-NisEffectiveRoute
        if ($route) {
            $text += "`r`nRoute choisie par Windows vers Internet : $($route.Alias)"
            if ($route.SourceAddress) { $text += " (source $($route.SourceAddress)" ; if ($route.NextHop) { $text += ", passerelle $($route.NextHop)" } ; $text += ")" }
            if ($ExpectedFirst) {
                if ($route.InterfaceIndex -eq $ExpectedFirst.InterfaceIndex) { $text += "  - conforme à l'ordre choisi." }
                else { $text += "  - ATTENTION : la 1re interface connectée de votre ordre est $($ExpectedFirst.Alias)." }
            }
        }
    } catch {
        $text += "`r`nRoute vers Internet : indéterminée ($($_.Exception.Message))"
    }
    return $text
}

# Test ping (job en arrière-plan, suivi par un timer pour ne pas figer la fenêtre)
$script:PingJob = $null
$script:PingButtons = @()
$pingTimer = New-Object Windows.Forms.Timer
$pingTimer.Interval = 500
$pingTimer.Add_Tick({
    if (-not $script:PingJob -or $script:PingJob.State -eq 'Running') { return }
    $pingTimer.Stop()
    $job = $script:PingJob
    $script:PingJob = $null
    foreach ($b in $script:PingButtons) { $b.Enabled = $true; $b.Text = $b.Tag }
    try {
        $r = Receive-Job -Job $job -ErrorAction Stop
        $ok = 'échec'
        if ($r.Ping) { $ok = 'OK' }
        $msg = "Interface utilisée : $($r.Alias)`nAdresse source : $($r.Source)`nPing 8.8.8.8 : $ok"
        Write-UiLog ("Test ping : " + ($msg -replace "`n", ' | '))
        $txtSimpleResult.AppendText("`r`nTest ping : interface $($r.Alias), source $($r.Source), ping $ok")
        Show-Msg $msg "Test de connexion"
    } catch {
        Write-UiLog "Test ping : erreur - $($_.Exception.Message)"
        Show-Msg "Erreur : $($_.Exception.Message)" "Test de connexion" Error
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
})

function Start-PingTest {
    if ($script:PingJob) { return }
    foreach ($b in $script:PingButtons) { $b.Enabled = $false; $b.Text = "Test en cours..." }
    Write-UiLog "Test ping vers 8.8.8.8..."
    $script:PingJob = Start-Job -ScriptBlock {
        $r = Test-NetConnection -ComputerName 8.8.8.8 -WarningAction SilentlyContinue
        [PSCustomObject]@{ Alias = $r.InterfaceAlias; Source = $r.SourceAddress.IPAddress; Ping = $r.PingSucceeded }
    }
    $pingTimer.Start()
}

function New-PingButton {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text = "Tester l'interface prioritaire (ping 8.8.8.8)")
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text
    $b.Tag = $Text
    $b.Location = New-Object Drawing.Point($X, $Y)
    $b.Size = New-Object Drawing.Size($W, $H)
    $b.BackColor = [System.Drawing.Color]::LightSkyBlue
    $b.Add_Click({ Start-PingTest })
    $script:PingButtons += $b
    return $b
}

function New-InfoButton {
    param([int]$X, [int]$Y, [string]$Title, [string]$Text)
    $b = New-Object Windows.Forms.Button
    $b.Text = "i"
    $b.Size = New-Object Drawing.Size(22, 22)
    $b.Location = New-Object Drawing.Point($X, $Y)
    $b.Font = $fontInfo
    $b.FlatStyle = "Flat"
    $b.AccessibleName = "Aide : $Title"
    $b.Tag = @($Title, $Text)
    $b.Add_Click({ param($src) Show-Msg $src.Tag[1] $src.Tag[0] })
    return $b
}

$helpIPv6 = "Désactiver l'IPv6 sur une interface force Windows à utiliser uniquement l'IPv4 pour le routage sur cette carte.`n`nCela peut aider à forcer la priorité réseau car Windows utilise parfois l'IPv6 pour router le trafic, contournant les métriques IPv4.`n`nImpact :`n- Aucun impact sur la majorité des usages (web, jeux, etc.)`n- Peut empêcher certains services locaux utilisant exclusivement IPv6`n- Réversible à tout moment en recochant la case puis en appliquant"

$helpMetrics = "Windows choisit la route dont la MÉTRIQUE TOTALE est la plus petite :`n   métrique totale = métrique d'interface + métrique de route (0.0.0.0/0)`n`n- Métrique auto : Windows calcule la métrique d'interface selon le débit de la carte. Décochez pour fixer votre valeur (1 à 9999).`n- Métrique interface : priorité de la carte (IPv4).`n- Métrique route : priorité de la route par défaut de la carte (0 à 9999). Vide si la carte n'a pas de route par défaut (déconnectée).`n- IPv6 activé / Métrique IPv6 : le trafic IPv6 suit ses propres métriques. Laissez la métrique IPv6 vide pour le mode automatique.`n`nLes modifications ne sont faites qu'en cliquant sur Appliquer, après confirmation. Les lignes modifiées sont surlignées en jaune."

$helpScheme = "L'ordre de la liste devient l'ordre de priorité, pour toutes les interfaces :`n`n   rang 1 : interface 10 + route 0  = total 10`n   rang 2 : interface 20 + route 10 = total 30`n   rang 3 : interface 30 + route 20 = total 50`n   ...`n`nLes métriques totales sont strictement croissantes et espacées de 20 : la 1re interface connectée est toujours utilisée, puis la suivante si elle se déconnecte, etc.`n`nUne interface déconnectée ou absente garde son rang : elle retrouvera sa place à son retour.`n`nOption IPv6 : la métrique d'interface IPv6 reçoit la même valeur (10, 20, 30...).`n`nRéinitialiser remet tout en automatique (comportement Windows) et oublie l'ordre sauvegardé."

# ---------------------------------------------------------------------------
# Onglets
# ---------------------------------------------------------------------------

$tabs = New-Object Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(10, 8)
$tabs.Size = New-Object Drawing.Size(980, 500)
$form.Controls.Add($tabs)

$tabSimple = New-Object Windows.Forms.TabPage
$tabSimple.Text = "Simple"
$tabSimple.UseVisualStyleBackColor = $true
$tabs.TabPages.Add($tabSimple)

$tabAdv = New-Object Windows.Forms.TabPage
$tabAdv.Text = "Avancé"
$tabAdv.UseVisualStyleBackColor = $true
$tabs.TabPages.Add($tabAdv)

# ===========================================================================
# VUE SIMPLE : classer les interfaces
# ===========================================================================

$script:SimpleEntries = @()

$lblSimple = New-Object Windows.Forms.Label
$lblSimple.Text = "Classez les interfaces de la plus prioritaire (en haut) à la moins prioritaire (en bas) : glisser-déposer, boutons ▲ ▼ ou Ctrl+Haut / Ctrl+Bas, puis « Appliquer l'ordre »."
$lblSimple.Location = New-Object Drawing.Point(12, 10)
$lblSimple.Size = New-Object Drawing.Size(900, 20)
$tabSimple.Controls.Add($lblSimple)

$tabSimple.Controls.Add((New-InfoButton -X 935 -Y 8 -Title "Priorités automatiques" -Text $helpScheme))

$lvSimple = New-Object Windows.Forms.ListView
$lvSimple.Location = New-Object Drawing.Point(12, 35)
$lvSimple.Size = New-Object Drawing.Size(735, 270)
$lvSimple.View = [Windows.Forms.View]::Details
$lvSimple.FullRowSelect = $true
$lvSimple.MultiSelect = $false
$lvSimple.HideSelection = $false
$lvSimple.GridLines = $true
$lvSimple.AllowDrop = $true
$lvSimple.AccessibleName = "Interfaces classées par priorité"
foreach ($c in @(@('Rang', 45), @('Interface', 140), @('Type', 65), @('État', 90), @('Adresse IPv4', 100), @('Métrique actuelle', 160), @('Après application', 110))) {
    [void]$lvSimple.Columns.Add($c[0], $c[1])
}
$tabSimple.Controls.Add($lvSimple)

function Show-SimpleList {
    param([int]$SelectIndex = -1)
    $plan = @(Get-NisPriorityPlan -Entries $script:SimpleEntries)
    $lvSimple.BeginUpdate()
    $lvSimple.Items.Clear()
    for ($i = 0; $i -lt $script:SimpleEntries.Count; $i++) {
        $e = $script:SimpleEntries[$i]
        $p = $plan[$i]
        $item = New-Object Windows.Forms.ListViewItem([string]($i + 1))
        [void]$item.SubItems.Add([string]$e.Alias)
        [void]$item.SubItems.Add([string]$e.Kind)
        [void]$item.SubItems.Add((Format-StatusText $e))
        $ip = ''
        if ($e.State) { $ip = $e.State.IPv4Address }
        [void]$item.SubItems.Add([string]$ip)
        [void]$item.SubItems.Add((Format-CurrentMetric $e.State))
        if ($e.Present) {
            [void]$item.SubItems.Add("$($p.InterfaceMetric) + $($p.RouteMetric) = $($p.TotalMetric)")
        } else {
            [void]$item.SubItems.Add("rang conservé")
        }
        if (-not $e.Present -or -not $e.State.IsUp) { $item.ForeColor = [System.Drawing.Color]::Gray }
        [void]$lvSimple.Items.Add($item)
    }
    $lvSimple.EndUpdate()
    if ($SelectIndex -ge 0 -and $SelectIndex -lt $lvSimple.Items.Count) {
        $lvSimple.Items[$SelectIndex].Selected = $true
        $lvSimple.Items[$SelectIndex].Focused = $true
        $lvSimple.EnsureVisible($SelectIndex)
    }
    Update-SimpleButtons
}

function Update-SimpleView {
    param([switch]$KeepOrder)
    $all = Get-UiStates -IncludeVirtual
    if ($null -eq $all) { return }
    if ($KeepOrder) { $saved = $script:SimpleEntries } else { $saved = @(Read-NisOrder) }
    if (-not $KeepOrder -and -not $chkSimpleVirtual.Checked) {
        # Une carte virtuelle classée lors d'un précédent « Appliquer l'ordre » doit rester dans l'ordre
        $rankedVirtual = @($all | Where-Object { $st = $_; -not $st.IsUsable -and @($saved | Where-Object { ($_.Guid -and $st.Guid -and $_.Guid -eq $st.Guid) -or ($_.Alias -eq $st.Alias) }).Count -gt 0 })
        if ($rankedVirtual.Count -gt 0) {
            $chkSimpleVirtual.Checked = $true
            Write-UiLog "Vue Simple : cartes virtuelles affichées car présentes dans l'ordre sauvegardé ($(($rankedVirtual | ForEach-Object { $_.Alias }) -join ', '))."
        }
    }
    $script:SimpleEntries = @(Merge-NisOrder -SavedOrder $saved -States $all -UsableOnly:(-not $chkSimpleVirtual.Checked))
    Show-SimpleList
    if ($null -ne $all) {
        $first = $script:SimpleEntries | Where-Object { $_.Present -and $_.State.IsUp -and $null -ne $_.State.EffectiveMetric } | Select-Object -First 1
        $expected = $null
        if ($first) { $expected = $first.State }
        $txtSimpleResult.Text = Get-EffectiveSummary -AllStates $all -ExpectedFirst $expected
    }
}

function Move-SimpleEntry {
    param([int]$From, [int]$To)
    if ($From -lt 0 -or $To -lt 0 -or $To -ge $script:SimpleEntries.Count -or $From -eq $To) { return }
    $script:SimpleEntries = @(Move-NisListItem -Items $script:SimpleEntries -From $From -To $To)
    Show-SimpleList -SelectIndex $To
    $lblSimpleDirty.Text = "Ordre modifié, non appliqué."
}

function Move-SimpleSelection {
    param([int]$Delta)
    if ($lvSimple.SelectedIndices.Count -eq 0) { return }
    $from = $lvSimple.SelectedIndices[0]
    Move-SimpleEntry -From $from -To ($from + $Delta)
}

# Clavier : Ctrl+Haut / Ctrl+Bas déplacent la ligne sélectionnée
$lvSimple.Add_KeyDown({
    param($src, $e)
    if ($e.Control -and $e.KeyCode -eq [Windows.Forms.Keys]::Up) { Move-SimpleSelection -1; $e.Handled = $true; $e.SuppressKeyPress = $true }
    elseif ($e.Control -and $e.KeyCode -eq [Windows.Forms.Keys]::Down) { Move-SimpleSelection 1; $e.Handled = $true; $e.SuppressKeyPress = $true }
})
$lvSimple.Add_SelectedIndexChanged({ Update-SimpleButtons })

# Glisser-déposer : la ligne déposée prend la place de la ligne survolée
$script:DragTarget = -1
function Set-DragTarget {
    param([int]$Index)
    if ($script:DragTarget -ge 0 -and $script:DragTarget -lt $lvSimple.Items.Count) { $lvSimple.Items[$script:DragTarget].BackColor = $lvSimple.BackColor }
    $script:DragTarget = $Index
    if ($Index -ge 0 -and $Index -lt $lvSimple.Items.Count) { $lvSimple.Items[$Index].BackColor = [System.Drawing.Color]::LightSteelBlue }
}
$lvSimple.Add_ItemDrag({
    param($src, $e)
    [void]$lvSimple.DoDragDrop($e.Item, [Windows.Forms.DragDropEffects]::Move)
})
$lvSimple.Add_DragEnter({ param($src, $e) $e.Effect = [Windows.Forms.DragDropEffects]::Move })
$lvSimple.Add_DragOver({
    param($src, $e)
    $e.Effect = [Windows.Forms.DragDropEffects]::Move
    $pt = $lvSimple.PointToClient((New-Object Drawing.Point($e.X, $e.Y)))
    $hit = $lvSimple.GetItemAt(5, $pt.Y)
    if ($hit) { Set-DragTarget $hit.Index } elseif ($lvSimple.Items.Count -gt 0) { Set-DragTarget ($lvSimple.Items.Count - 1) }
})
$lvSimple.Add_DragLeave({ Set-DragTarget -1 })
$lvSimple.Add_DragDrop({
    param($src, $e)
    $target = $script:DragTarget
    Set-DragTarget -1
    $item = $e.Data.GetData([Windows.Forms.ListViewItem])
    if ($item -and $target -ge 0) { Move-SimpleEntry -From $item.Index -To $target }
})

$btnUp = New-Object Windows.Forms.Button
$btnUp.Text = "▲ &Monter"
$btnUp.Location = New-Object Drawing.Point(760, 35)
$btnUp.Size = New-Object Drawing.Size(200, 32)
$btnUp.AccessibleName = "Monter l'interface sélectionnée"
$btnUp.Add_Click({ Move-SimpleSelection -1; $lvSimple.Focus() | Out-Null })
$tabSimple.Controls.Add($btnUp)

$btnDown = New-Object Windows.Forms.Button
$btnDown.Text = "▼ &Descendre"
$btnDown.Location = New-Object Drawing.Point(760, 72)
$btnDown.Size = New-Object Drawing.Size(200, 32)
$btnDown.AccessibleName = "Descendre l'interface sélectionnée"
$btnDown.Add_Click({ Move-SimpleSelection 1; $lvSimple.Focus() | Out-Null })
$tabSimple.Controls.Add($btnDown)

$btnForget = New-Object Windows.Forms.Button
$btnForget.Text = "Oublier (interface absente)"
$btnForget.Location = New-Object Drawing.Point(760, 109)
$btnForget.Size = New-Object Drawing.Size(200, 28)
$btnForget.Add_Click({
    if ($lvSimple.SelectedIndices.Count -eq 0) { return }
    $i = $lvSimple.SelectedIndices[0]
    $e = $script:SimpleEntries[$i]
    if ($e.Present) { return }
    $script:SimpleEntries = @($script:SimpleEntries | Where-Object { -not [object]::ReferenceEquals($_, $e) })
    Write-UiLog "Vue Simple : $($e.Alias) retirée de l'ordre (appliquez pour enregistrer)."
    $lblSimpleDirty.Text = "Ordre modifié, non appliqué."
    Show-SimpleList -SelectIndex ([Math]::Min($i, $script:SimpleEntries.Count - 1))
})
$tabSimple.Controls.Add($btnForget)

function Update-SimpleButtons {
    $sel = -1
    if ($lvSimple.SelectedIndices.Count -gt 0) { $sel = $lvSimple.SelectedIndices[0] }
    $btnUp.Enabled = ($sel -gt 0)
    $btnDown.Enabled = ($sel -ge 0 -and $sel -lt $script:SimpleEntries.Count - 1)
    $btnForget.Enabled = ($sel -ge 0 -and -not $script:SimpleEntries[$sel].Present)
}

$chkSimpleVirtual = New-Object Windows.Forms.CheckBox
$chkSimpleVirtual.Text = "Inclure les cartes virtuelles (VPN, Hyper-V...)"
$chkSimpleVirtual.Location = New-Object Drawing.Point(760, 150)
$chkSimpleVirtual.Size = New-Object Drawing.Size(210, 34)
$chkSimpleVirtual.Add_Click({ Update-SimpleView -KeepOrder })
$tabSimple.Controls.Add($chkSimpleVirtual)

$chkSimpleIPv6 = New-Object Windows.Forms.CheckBox
$chkSimpleIPv6.Text = "Appliquer aussi l'ordre aux métriques IPv6"
$chkSimpleIPv6.Location = New-Object Drawing.Point(760, 188)
$chkSimpleIPv6.Size = New-Object Drawing.Size(210, 34)
$chkSimpleIPv6.Checked = $true
$tabSimple.Controls.Add($chkSimpleIPv6)

$btnSimpleRefresh = New-Object Windows.Forms.Button
$btnSimpleRefresh.Text = "&Rafraîchir"
$btnSimpleRefresh.Location = New-Object Drawing.Point(760, 230)
$btnSimpleRefresh.Size = New-Object Drawing.Size(200, 28)
$btnSimpleRefresh.Add_Click({ Update-SimpleView -KeepOrder; Write-UiLog "Vue Simple rafraîchie." })
$tabSimple.Controls.Add($btnSimpleRefresh)

$lblSimpleDirty = New-Object Windows.Forms.Label
$lblSimpleDirty.Location = New-Object Drawing.Point(760, 265)
$lblSimpleDirty.Size = New-Object Drawing.Size(200, 36)
$lblSimpleDirty.ForeColor = [System.Drawing.Color]::DarkOrange
$tabSimple.Controls.Add($lblSimpleDirty)

$btnSimpleApply = New-Object Windows.Forms.Button
$btnSimpleApply.Text = "Appliquer l'ordre"
$btnSimpleApply.Location = New-Object Drawing.Point(12, 315)
$btnSimpleApply.Size = New-Object Drawing.Size(240, 45)
$btnSimpleApply.BackColor = [System.Drawing.Color]::LightGreen
$btnSimpleApply.Font = $fontBold
$btnSimpleApply.Add_Click({
    $states = Get-UiStates -IncludeVirtual
    if ($null -eq $states) { return }
    # Rafraîchit l'état des interfaces sans changer l'ordre choisi
    $entries = @(Merge-NisOrder -SavedOrder $script:SimpleEntries -States $states -UsableOnly:(-not $chkSimpleVirtual.Checked))
    if ($entries.Count -ne $script:SimpleEntries.Count) {
        $script:SimpleEntries = $entries
        Show-SimpleList
        Write-UiLog "Vue Simple : la liste des interfaces a changé, vérifiez l'ordre puis appliquez à nouveau."
        Show-Msg "La liste des interfaces a changé depuis l'affichage. Vérifiez l'ordre puis cliquez à nouveau sur « Appliquer l'ordre »." "Appliquer l'ordre" Warning
        return
    }
    $script:SimpleEntries = $entries
    $plan = @(Get-NisPriorityPlan -Entries $entries)
    $desired = @(ConvertTo-NisDesiredFromPlan -Plan $plan -IncludeIPv6:$chkSimpleIPv6.Checked)
    $summary = @("Nouvel ordre de priorité :")
    foreach ($p in $plan) {
        if ($p.Present) { $summary += "  $($p.Rank). $($p.Alias) : $($p.InterfaceMetric) + $($p.RouteMetric) = $($p.TotalMetric)" }
        else { $summary += "  $($p.Rank). $($p.Alias) : absente (rang conservé)" }
    }
    if (-not $chkSimpleVirtual.Checked) {
        $hiddenManual = @($states | Where-Object { -not $_.IsUsable -and -not $_.AutomaticMetric })
        if ($hiddenManual.Count -gt 0) {
            $summary += ""
            $summary += "Note : cartes virtuelles non classées, leur métrique manuelle est conservée : " + (($hiddenManual | ForEach-Object { "$($_.Alias) ($($_.InterfaceMetric))" }) -join ', ') + ". Cochez « Inclure les cartes virtuelles » pour les classer."
        }
    }
    $result = Invoke-UiChange -Desired $desired -CurrentStates $states -Title "Appliquer l'ordre" -Summary ($summary -join "`n")
    if ($result -and $result.Success) {
        try {
            Save-NisOrder -Entries $entries
            Write-UiLog "Ordre enregistré dans $(Get-NisOrderFilePath)."
        } catch {
            Write-UiLog "Ordre appliqué mais non enregistré : $($_.Exception.Message)"
        }
        $lblSimpleDirty.Text = ""
        Update-SimpleView -KeepOrder
        Update-AdvancedView
        Write-UiLog ($txtSimpleResult.Text -replace "`r`n", ' | ')
    } elseif ($result) {
        Update-SimpleView -KeepOrder
        Update-AdvancedView
    }
})
$tabSimple.Controls.Add($btnSimpleApply)

function Invoke-UiReset {
    $states = Get-UiStates -IncludeVirtual
    if ($null -eq $states) { return $false }
    $desired = @(Get-NisResetDesired -States $states)
    $result = Invoke-UiChange -Desired $desired -CurrentStates $states -Title "Réinitialiser" -Summary "Toutes les interfaces repassent en métrique automatique (IPv4 et IPv6), les métriques de route par défaut reviennent à 0, et l'ordre sauvegardé de la vue Simple est oublié. Windows gère à nouveau les priorités."
    if ($result -and $result.Success) {
        try { Clear-NisOrder } catch { Write-UiLog "Ordre sauvegardé non supprimé : $($_.Exception.Message)" }
        Write-UiLog "Réinitialisation terminée, ordre sauvegardé oublié."
        $lblSimpleDirty.Text = ""
        Update-SimpleView
        Update-AdvancedView -DiscardEdits
        return $true
    }
    # Annulé ou échec : on garde l'ordre non appliqué et les saisies de la vue Avancé
    Update-SimpleView -KeepOrder
    Update-AdvancedView
    return $false
}

$btnSimpleReset = New-Object Windows.Forms.Button
$btnSimpleReset.Text = "Réinitialiser (automatique)"
$btnSimpleReset.Location = New-Object Drawing.Point(262, 315)
$btnSimpleReset.Size = New-Object Drawing.Size(240, 45)
$btnSimpleReset.BackColor = [System.Drawing.Color]::LightCoral
$btnSimpleReset.Font = $fontBold
$btnSimpleReset.Add_Click({ [void](Invoke-UiReset) })
$tabSimple.Controls.Add($btnSimpleReset)

$tabSimple.Controls.Add((New-PingButton -X 512 -Y 315 -W 235 -H 45 -Text "Tester (ping 8.8.8.8)"))

$lblSimpleResult = New-Object Windows.Forms.Label
$lblSimpleResult.Text = "Résultat effectif :"
$lblSimpleResult.Location = New-Object Drawing.Point(12, 370)
$lblSimpleResult.AutoSize = $true
$tabSimple.Controls.Add($lblSimpleResult)

$txtSimpleResult = New-Object Windows.Forms.TextBox
$txtSimpleResult.Multiline = $true
$txtSimpleResult.ReadOnly = $true
$txtSimpleResult.ScrollBars = "Vertical"
$txtSimpleResult.Location = New-Object Drawing.Point(12, 390)
$txtSimpleResult.Size = New-Object Drawing.Size(948, 70)
$txtSimpleResult.BackColor = [System.Drawing.Color]::White
$txtSimpleResult.AccessibleName = "Résultat effectif"
$tabSimple.Controls.Add($txtSimpleResult)

# ===========================================================================
# VUE AVANCÉ : tous les paramètres, interface par interface
# ===========================================================================

$chkAdvAll = New-Object Windows.Forms.CheckBox
$chkAdvAll.Text = "Afficher toutes les cartes (virtuelles comprises)"
$chkAdvAll.Location = New-Object Drawing.Point(12, 8)
$chkAdvAll.AutoSize = $true
$chkAdvAll.Add_Click({ Update-AdvancedView })
$tabAdv.Controls.Add($chkAdvAll)

$tabAdv.Controls.Add((New-InfoButton -X 330 -Y 7 -Title "Métriques - Information" -Text $helpMetrics))

$btnAdvRefresh = New-Object Windows.Forms.Button
$btnAdvRefresh.Text = "Rafraîchir"
$btnAdvRefresh.Location = New-Object Drawing.Point(840, 5)
$btnAdvRefresh.Size = New-Object Drawing.Size(120, 26)
$btnAdvRefresh.Add_Click({
    $hasPending = @($dgv.Rows | Where-Object { [string]$_.Cells['Modif'].Value -eq 'non appliqué' }).Count -gt 0
    if ($hasPending -and -not (Confirm-Msg "Des saisies ne sont pas appliquées. Les abandonner et relire l'état du système ?" "Rafraîchir")) { return }
    Update-AdvancedView -DiscardEdits
    Write-UiLog "Vue Avancé rafraîchie."
})
$tabAdv.Controls.Add($btnAdvRefresh)

$dgv = New-Object Windows.Forms.DataGridView
$dgv.Location = New-Object Drawing.Point(12, 36)
$dgv.Size = New-Object Drawing.Size(948, 205)
$dgv.AllowUserToAddRows = $false
$dgv.AllowUserToDeleteRows = $false
$dgv.AllowUserToResizeRows = $false
$dgv.RowHeadersVisible = $false
$dgv.SelectionMode = [Windows.Forms.DataGridViewSelectionMode]::CellSelect
$dgv.MultiSelect = $false
$dgv.EditMode = [Windows.Forms.DataGridViewEditMode]::EditOnEnter
$dgv.BackgroundColor = [System.Drawing.Color]::White
$dgv.ColumnHeadersHeightSizeMode = [Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
$dgv.ColumnHeadersDefaultCellStyle.WrapMode = [Windows.Forms.DataGridViewTriState]::True
$dgv.AccessibleName = "Paramètres par interface"

function Add-GridColumn {
    param([string]$Name, [string]$Header, [int]$Width, [switch]$Check, [switch]$ReadOnly)
    if ($Check) { $col = New-Object Windows.Forms.DataGridViewCheckBoxColumn } else { $col = New-Object Windows.Forms.DataGridViewTextBoxColumn }
    $col.Name = $Name
    $col.HeaderText = $Header
    $col.Width = $Width
    $col.ReadOnly = [bool]$ReadOnly
    $col.SortMode = [Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    if ($ReadOnly) { $col.DefaultCellStyle.BackColor = [System.Drawing.Color]::WhiteSmoke }
    [void]$dgv.Columns.Add($col)
}
Add-GridColumn -Name 'Id' -Header 'ID' -Width 38 -ReadOnly
Add-GridColumn -Name 'Interface' -Header 'Interface' -Width 165 -ReadOnly
Add-GridColumn -Name 'Etat' -Header 'État' -Width 85 -ReadOnly
Add-GridColumn -Name 'Auto' -Header 'Métrique auto' -Width 70 -Check
Add-GridColumn -Name 'IfMetric' -Header 'Métrique interface (IPv4)' -Width 95
Add-GridColumn -Name 'RouteMetric' -Header 'Métrique route 0.0.0.0/0' -Width 95
Add-GridColumn -Name 'Total' -Header 'Total effectif' -Width 75 -ReadOnly
Add-GridColumn -Name 'IPv6' -Header 'IPv6 activé' -Width 65 -Check
Add-GridColumn -Name 'IPv6Metric' -Header 'Métrique IPv6 (vide = auto)' -Width 105
Add-GridColumn -Name 'Modif' -Header 'Modifié' -Width 130 -ReadOnly
$tabAdv.Controls.Add($dgv)

$script:AdvLoading = $false

function Set-CellLocked {
    param($Cell, [bool]$Locked, [string]$Tip = '')
    $Cell.ReadOnly = $Locked
    if ($Locked) { $Cell.Style.BackColor = [System.Drawing.Color]::WhiteSmoke; $Cell.Style.ForeColor = [System.Drawing.Color]::Gray }
    else { $Cell.Style.BackColor = [System.Drawing.Color]::Empty; $Cell.Style.ForeColor = [System.Drawing.Color]::Empty }
    $Cell.ToolTipText = $Tip
}

function Update-AdvancedView {
    <#
      Recharge le tableau depuis le système. Les saisies non appliquées (lignes jaunes) sont conservées,
      sauf avec -DiscardEdits ou pour les interfaces listées dans -DropEdits (venant d'être appliquées).
    #>
    param([int[]]$DropEdits = @(), [switch]$DiscardEdits)
    $states = Get-UiStates -IncludeVirtual:$chkAdvAll.Checked
    if ($null -eq $states) { return }
    [void]$dgv.EndEdit()
    $pending = @{}
    if (-not $DiscardEdits) {
        foreach ($r in $dgv.Rows) {
            if ([string]$r.Cells['Modif'].Value -ne 'non appliqué' -or -not $r.Tag) { continue }
            $idx = [int]$r.Tag.InterfaceIndex
            if ($DropEdits -contains $idx) { continue }
            $pending[$idx] = @{ Auto = $r.Cells['Auto'].Value; IfMetric = $r.Cells['IfMetric'].Value; RouteMetric = $r.Cells['RouteMetric'].Value; IPv6 = $r.Cells['IPv6'].Value; IPv6Metric = $r.Cells['IPv6Metric'].Value }
        }
    }
    $script:AdvLoading = $true
    $dgv.Rows.Clear()
    foreach ($s in $states) {
        $row = $dgv.Rows[$dgv.Rows.Add()]
        $row.Tag = $s
        $row.Cells['Id'].Value = [string]$s.InterfaceIndex
        $row.Cells['Interface'].Value = $s.Alias
        $row.Cells['Interface'].ToolTipText = "$($s.Description) - $($s.Kind) - $($s.IPv4Address)"
        $row.Cells['Etat'].Value = (Format-StatusText ([pscustomobject]@{ Present = $true; State = $s }))
        $row.Cells['Auto'].Value = [bool]$s.AutomaticMetric
        $row.Cells['IfMetric'].Value = [string]$s.InterfaceMetric
        Set-CellLocked $row.Cells['IfMetric'] ([bool]$s.AutomaticMetric) "Décochez « Métrique auto » pour fixer la valeur"
        if (@($s.Routes).Count -gt 0) {
            $row.Cells['RouteMetric'].Value = [string]$s.RouteMetric
            $tip = (@($s.Routes) | ForEach-Object { "via $($_.NextHop) : $($_.RouteMetric)" }) -join "`n"
            Set-CellLocked $row.Cells['RouteMetric'] $false $tip
        } else {
            $row.Cells['RouteMetric'].Value = ''
            Set-CellLocked $row.Cells['RouteMetric'] $true "Pas de route par défaut sur cette interface"
        }
        $row.Cells['RouteMetric'].Tag = [string]$row.Cells['RouteMetric'].Value
        if ($null -ne $s.EffectiveMetric) { $row.Cells['Total'].Value = "$($s.InterfaceMetric) + $($s.RouteMetric) = $($s.EffectiveMetric)" } else { $row.Cells['Total'].Value = '-' }
        if ($null -ne $s.IPv6Enabled) {
            $row.Cells['IPv6'].Value = [bool]$s.IPv6Enabled
            Set-CellLocked $row.Cells['IPv6'] $false
        } else {
            $row.Cells['IPv6'].Value = $false
            Set-CellLocked $row.Cells['IPv6'] $true "Liaison IPv6 non modifiable pour cette carte"
        }
        if ($s.HasIPv6Interface) {
            if ($s.IPv6AutomaticMetric) { $row.Cells['IPv6Metric'].Value = '' } else { $row.Cells['IPv6Metric'].Value = [string]$s.IPv6InterfaceMetric }
            Set-CellLocked $row.Cells['IPv6Metric'] $false "Actuellement : $(if ($s.IPv6AutomaticMetric) { 'auto' } else { 'manuelle' }) ($($s.IPv6InterfaceMetric)). Vide = automatique."
        } else {
            $row.Cells['IPv6Metric'].Value = ''
            Set-CellLocked $row.Cells['IPv6Metric'] $true "Pas d'interface IPv6 active (IPv6 désactivé ?)"
        }
        $row.Cells['Modif'].Value = ''
        if (-not $s.IsUp) { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DimGray }
    }
    $script:AdvLoading = $false
    # Remet les saisies non appliquées (CellValueChanged les resurligne en jaune)
    if ($pending.Count -gt 0) {
        foreach ($r in $dgv.Rows) {
            $idx = [int]$r.Tag.InterfaceIndex
            if (-not $pending.ContainsKey($idx)) { continue }
            $v = $pending[$idx]
            foreach ($col in 'Auto', 'IfMetric', 'RouteMetric', 'IPv6', 'IPv6Metric') {
                if (-not $r.Cells[$col].ReadOnly -or $col -eq 'IfMetric') { $r.Cells[$col].Value = $v[$col] }
            }
            $r.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightYellow
            $r.Cells['Modif'].Value = 'non appliqué'
        }
        Write-UiLog "Vue Avancé : saisies non appliquées conservées pour $($pending.Count) interface(s)."
    }
    Update-Diagnostic
}

# Les cases à cocher sont validées immédiatement (sinon la valeur n'est prise qu'en quittant la cellule)
$dgv.Add_CurrentCellDirtyStateChanged({
    if ($dgv.IsCurrentCellDirty -and $dgv.CurrentCell -is [Windows.Forms.DataGridViewCheckBoxCell]) {
        [void]$dgv.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
})
$dgv.Add_CellValueChanged({
    param($src, $e)
    if ($script:AdvLoading -or $e.RowIndex -lt 0) { return }
    $row = $dgv.Rows[$e.RowIndex]
    $colName = $dgv.Columns[$e.ColumnIndex].Name
    if ($colName -eq 'Modif') { return }
    if ($colName -eq 'Auto') {
        $auto = [bool]$row.Cells['Auto'].Value
        Set-CellLocked $row.Cells['IfMetric'] $auto "Décochez « Métrique auto » pour fixer la valeur"
    }
    $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightYellow
    $row.Cells['Modif'].Value = 'non appliqué'
})
$dgv.Add_DataError({ param($src, $e) $e.ThrowException = $false })

function Get-AdvancedRowDesired {
    param($Row)
    $s = $Row.Tag
    $v6 = $null
    if ($null -ne $s.IPv6Enabled) { $v6 = [bool]$Row.Cells['IPv6'].Value }
    $routeText = [string]$Row.Cells['RouteMetric'].Value
    # Valeur de route non modifiée : on n'y touche pas (préserve des routes multiples aux métriques différentes)
    if ($routeText -eq [string]$Row.Cells['RouteMetric'].Tag) { $routeText = '' }
    return (ConvertTo-NisDesiredFromInput -State $s -AutomaticMetric ([bool]$Row.Cells['Auto'].Value) `
            -InterfaceMetricText ([string]$Row.Cells['IfMetric'].Value) -RouteMetricText $routeText `
            -IPv6Enabled $v6 -IPv6MetricText ([string]$Row.Cells['IPv6Metric'].Value))
}

function Invoke-AdvancedApply {
    param([object[]]$Rows, [string]$Title)
    [void]$dgv.EndEdit()
    $rowList = @($Rows | Where-Object { $null -ne $_ })
    if ($rowList.Count -eq 0) { Show-Msg "Sélectionnez une ligne (cliquez dans une cellule de l'interface)." $Title Warning; return }
    $desired = @()
    $errs = @()
    foreach ($r in $rowList) {
        $conv = Get-AdvancedRowDesired $r
        $errs += @($conv.Errors)
        $desired += $conv.Desired
    }
    if ($errs.Count -gt 0) {
        Write-UiLog "$Title : valeurs invalides, rien n'a été modifié."
        foreach ($e in $errs) { Write-UiLog "  - $e" }
        Show-Msg ("Aucune modification n'a été faite. Corrigez :`n`n- " + ($errs -join "`n- ")) "$Title - valeurs invalides" Warning
        return
    }
    $states = Get-UiStates -IncludeVirtual
    if ($null -eq $states) { return }
    $result = Invoke-UiChange -Desired $desired -CurrentStates $states -Title $Title
    $applied = @()
    if ($result -and $result.Success) { $applied = @($rowList | ForEach-Object { [int]$_.Tag.InterfaceIndex }) }
    Update-AdvancedView -DropEdits $applied
    Update-SimpleView -KeepOrder
}

$btnAdvApplyRow = New-Object Windows.Forms.Button
$btnAdvApplyRow.Text = "Appliquer la ligne"
$btnAdvApplyRow.Location = New-Object Drawing.Point(12, 248)
$btnAdvApplyRow.Size = New-Object Drawing.Size(150, 34)
$btnAdvApplyRow.BackColor = [System.Drawing.Color]::Honeydew
$btnAdvApplyRow.Add_Click({
    $row = $dgv.CurrentRow
    Invoke-AdvancedApply -Rows @($row) -Title "Appliquer la ligne"
})
$tabAdv.Controls.Add($btnAdvApplyRow)

$btnAdvApplyAll = New-Object Windows.Forms.Button
$btnAdvApplyAll.Text = "Appliquer tout"
$btnAdvApplyAll.Location = New-Object Drawing.Point(170, 248)
$btnAdvApplyAll.Size = New-Object Drawing.Size(150, 34)
$btnAdvApplyAll.BackColor = [System.Drawing.Color]::LightGreen
$btnAdvApplyAll.Font = New-Object Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnAdvApplyAll.Add_Click({ Invoke-AdvancedApply -Rows @($dgv.Rows) -Title "Appliquer tout" })
$tabAdv.Controls.Add($btnAdvApplyAll)

$btnAdvForce = New-Object Windows.Forms.Button
$btnAdvForce.Text = "Forcer la ligne en priorité (10 / autres 1000)"
$btnAdvForce.Location = New-Object Drawing.Point(328, 248)
$btnAdvForce.Size = New-Object Drawing.Size(285, 34)
$btnAdvForce.Add_Click({
    $row = $dgv.CurrentRow
    if (-not $row) { Show-Msg "Sélectionnez une ligne." "Forcer la priorité" Warning; return }
    $s = $row.Tag
    $states = Get-UiStates -IncludeVirtual
    if ($null -eq $states) { return }
    $desired = @(Get-NisForceOneDesired -States $states -InterfaceIndex $s.InterfaceIndex)
    [void](Invoke-UiChange -Desired $desired -CurrentStates $states -Title "Forcer la priorité" -Summary "$($s.Alias) : métrique 10 + route 0 = 10.`nAutres cartes physiques : 1000 + 1000 = 2000.")
    Update-AdvancedView
    Update-SimpleView -KeepOrder
})
$tabAdv.Controls.Add($btnAdvForce)

$btnAdvReset = New-Object Windows.Forms.Button
$btnAdvReset.Text = "Réinitialiser (automatique)"
$btnAdvReset.Location = New-Object Drawing.Point(621, 248)
$btnAdvReset.Size = New-Object Drawing.Size(200, 34)
$btnAdvReset.BackColor = [System.Drawing.Color]::LightCoral
$btnAdvReset.Add_Click({ [void](Invoke-UiReset) })
$tabAdv.Controls.Add($btnAdvReset)

$lblIPv6 = New-Object Windows.Forms.Label
$lblIPv6.Text = "IPv6 :"
$lblIPv6.Location = New-Object Drawing.Point(870, 256)
$lblIPv6.AutoSize = $true
$tabAdv.Controls.Add($lblIPv6)
$tabAdv.Controls.Add((New-InfoButton -X 910 -Y 253 -Title "IPv6 - Information" -Text $helpIPv6))

$labelDiag = New-Object Windows.Forms.Label
$labelDiag.Text = "État actuel des routes (IPv4) :"
$labelDiag.Location = New-Object Drawing.Point(12, 290)
$labelDiag.AutoSize = $true
$tabAdv.Controls.Add($labelDiag)

$txt = New-Object Windows.Forms.TextBox
$txt.Multiline = $true
$txt.ReadOnly = $true
$txt.ScrollBars = "Vertical"
$txt.Location = New-Object Drawing.Point(12, 308)
$txt.Size = New-Object Drawing.Size(560, 155)
$txt.BackColor = [System.Drawing.Color]::White
$txt.Font = New-Object Drawing.Font("Consolas", 8)
$txt.AccessibleName = "Diagnostic des routes"
$tabAdv.Controls.Add($txt)

function Update-Diagnostic {
    $all = Get-UiStates -IncludeVirtual
    if ($null -eq $all) { return }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("ROUTES PAR DÉFAUT (de la plus prioritaire à la moins prioritaire) :`r`n---------------------------`r`n")
    $order = @(Get-NisEffectiveOrder -States $all)
    foreach ($s in $order) {
        $auto = ''
        if ($s.AutomaticMetric) { $auto = ' (auto)' }
        [void]$sb.Append("-> $($s.Alias)`r`n   Interface: $($s.InterfaceMetric)$auto + Route: $($s.RouteMetric) = Total: $($s.EffectiveMetric)`r`n")
    }
    if ($order.Count -eq 0) { [void]$sb.Append("(aucune route par défaut)`r`n") }
    try {
        $route = Find-NisEffectiveRoute
        if ($route) { [void]$sb.Append("---------------------------`r`nUtilisée vers Internet : $($route.Alias) (source $($route.SourceAddress))`r`n") }
    } catch {
        [void]$sb.Append("---------------------------`r`nRoute vers Internet : indéterminée`r`n")
    }
    $txt.Text = $sb.ToString()
}

$grpHelp = New-Object Windows.Forms.GroupBox
$grpHelp.Text = " PRÉREQUIS && CONFIGURATION "
$grpHelp.Location = New-Object Drawing.Point(585, 288)
$grpHelp.Size = New-Object Drawing.Size(375, 178)
$tabAdv.Controls.Add($grpHelp)

$helpText = New-Object Windows.Forms.TextBox
$helpText.Location = New-Object Drawing.Point(10, 20)
$helpText.Size = New-Object Drawing.Size(355, 92)
$helpText.Multiline = $true
$helpText.ReadOnly = $true
$helpText.ScrollBars = "Vertical"
$helpText.BackColor = [System.Drawing.SystemColors]::Control
$helpText.BorderStyle = "None"
$helpText.Text = "A. ICÔNE SYSTÈME (Windows 11) :`r`nSur Windows 11, l'icône du system tray affiche toujours Ethernet tant qu'un câble est branché, même si le Wi-Fi est prioritaire. C'est normal : l'icône ne reflète pas le routage réel. Utilisez le bouton 'Tester' pour vérifier quelle interface est réellement utilisée.`r`n`r`nB. CRÉATION DU RACCOURCI :`r`n1. Clic-droit Bureau > Nouveau > Raccourci.`r`n2. Cible (Copiez-collez) :`r`n   powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`"`r`n   (ajoutez -Vue Avance pour ouvrir directement la vue Avancé)`r`n3. Nommez-le 'Gestionnaire Réseau'.`r`n`r`nC. PROPRIÉTÉS DU RACCOURCI :`r`n1. Clic-droit sur le raccourci > Propriétés.`r`n2. Bouton 'Avancé' > Cochez 'Exécuter en tant qu'administrateur'.`r`n`r`nD. LES DEUX VUES :`r`n- Simple : classez les interfaces, l'application calcule les métriques (10+0, 20+10, 30+20...).`r`n- Avancé : réglez chaque paramètre (métrique auto, métrique d'interface, métrique de route, IPv6) interface par interface.`r`nAucune modification n'est faite sans confirmation ; en cas d'erreur, tout est annulé."
$grpHelp.Controls.Add($helpText)

$grpHelp.Controls.Add((New-PingButton -X 10 -Y 116 -W 355 -H 28))

$btnNetCpl = New-Object Windows.Forms.Button
$btnNetCpl.Text = "Ouvrir les Connexions Réseau"
$btnNetCpl.Location = New-Object Drawing.Point(10, 148)
$btnNetCpl.Size = New-Object Drawing.Size(355, 24)
$btnNetCpl.FlatStyle = "Flat"
$btnNetCpl.Add_Click({ ncpa.cpl })
$grpHelp.Controls.Add($btnNetCpl)

# ---------------------------------------------------------------------------
# Démarrage
# ---------------------------------------------------------------------------

if ($Apercu) {
    foreach ($b in @($btnSimpleApply, $btnSimpleReset, $btnAdvApplyRow, $btnAdvApplyAll, $btnAdvForce, $btnAdvReset)) { $b.Enabled = $false }
    $dgv.ReadOnly = $true
}

if ($Vue -eq 'Avance') { $tabs.SelectedTab = $tabAdv } else { $tabs.SelectedTab = $tabSimple }

$form.Add_Shown({
    Write-UiLog "Démarrage$(if ($Apercu) { ' en mode aperçu (lecture seule)' })."
    Update-SimpleView
    Update-AdvancedView
    if ($lvSimple.Items.Count -gt 0) { $lvSimple.Items[0].Selected = $true }
    $lvSimple.Focus() | Out-Null
})
$form.Add_FormClosed({ $pingTimer.Stop(); if ($script:PingJob) { Remove-Job -Job $script:PingJob -Force -ErrorAction SilentlyContinue } })

[void]$form.ShowDialog()
