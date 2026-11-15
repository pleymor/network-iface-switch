# Tests Pester 5 de la logique (aucune modification réelle du système : tout est simulé).
# Lancer depuis la racine du dépôt :  Invoke-Pester ./tests

BeforeAll {
    # Fonctions vides du même nom que les cmdlets réseau : elles masquent les vraies cmdlets
    # (une fonction est prioritaire sur une cmdlet), ce qui garantit qu'aucun test ne modifie
    # le système, même sous Windows, et permet de les simuler (Mock) sous Linux.
    $stubs = @{
        'Get-NetIPInterface'         = 'param($AddressFamily, $InterfaceIndex, $ErrorAction)'
        'Set-NetIPInterface'         = 'param($InterfaceIndex, $AddressFamily, $AutomaticMetric, $InterfaceMetric, $ErrorAction)'
        'Get-NetRoute'               = 'param($DestinationPrefix, $InterfaceIndex, $NextHop, $AddressFamily, $ErrorAction)'
        'Set-NetRoute'               = 'param([Parameter(ValueFromPipeline = $true)]$InputObject, $RouteMetric, $ErrorAction) process { }'
        'Get-NetAdapter'             = 'param($ErrorAction)'
        'Get-NetIPAddress'           = 'param($AddressFamily, $ErrorAction)'
        'Get-NetAdapterBinding'      = 'param($Name, $ComponentID, $ErrorAction)'
        'Enable-NetAdapterBinding'   = 'param($Name, $ComponentID, $ErrorAction)'
        'Disable-NetAdapterBinding'  = 'param($Name, $ComponentID, $ErrorAction)'
        'Find-NetRoute'              = 'param($RemoteIPAddress, $ErrorAction)'
    }
    $script:StubNames = @($stubs.Keys)
    foreach ($name in $stubs.Keys) {
        Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create($stubs[$name]))
    }

    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'NetIfaceSwitch.Core.ps1')

    function New-TestState {
        param(
            [int]$Index, [string]$Alias, [string]$Guid = $null, [string]$Kind = 'Ethernet',
            [bool]$Auto = $true, [int]$Metric = 25, [object[]]$Routes = @(),
            [bool]$Usable = $true, $IPv6Enabled = $true, [bool]$HasIPv6 = $true,
            $IPv6Auto = $true, $IPv6Metric = 25
        )
        $routeMetric = $null
        if ($Routes.Count -gt 0) { $routeMetric = ($Routes | Measure-Object RouteMetric -Minimum).Minimum }
        $eff = $null
        if ($null -ne $routeMetric) { $eff = $Metric + $routeMetric }
        [pscustomobject]@{
            Key = (Get-NisEntryKey -Guid $Guid -Alias $Alias); InterfaceIndex = $Index; Alias = $Alias; Guid = $Guid
            Kind = $Kind; Status = 'Up'; IsUp = $true; IsPhysical = $Usable; IsLoopback = $false; IsUsable = $Usable
            IPv4Address = ''; AutomaticMetric = $Auto; InterfaceMetric = $Metric; Routes = $Routes
            RouteMetric = $routeMetric; EffectiveMetric = $eff; IPv6Enabled = $IPv6Enabled
            HasIPv6Interface = $HasIPv6; IPv6AutomaticMetric = $IPv6Auto; IPv6InterfaceMetric = $IPv6Metric
        }
    }
    function New-TestRoute([string]$NextHop, [int]$Metric) { [pscustomobject]@{ NextHop = $NextHop; RouteMetric = $Metric } }
}

AfterAll {
    foreach ($name in $script:StubNames) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue }
}

Describe 'Get-NisInterfaceKind' {
    It 'reconnait le Wi-Fi par le type de média' { Get-NisInterfaceKind -Alias 'Connexion' -PhysicalMediaType 'Native 802.11' | Should -Be 'Wi-Fi' }
    It 'reconnait le Wi-Fi par le nom (WiFi sans tiret)' { Get-NisInterfaceKind -Alias 'WiFi 2' | Should -Be 'Wi-Fi' }
    It 'reconnait l''Ethernet' { Get-NisInterfaceKind -Alias 'Ethernet 3' -PhysicalMediaType '802.3' | Should -Be 'Ethernet' }
    It 'classe le reste en Autre' { Get-NisInterfaceKind -Alias 'Cellulaire' -PhysicalMediaType 'Unspecified' | Should -Be 'Autre' }
}

Describe 'Get-NisPriorityPlan' {
    BeforeAll {
        $entries = @(
            [pscustomobject]@{ Key = 'a'; Alias = 'Wi-Fi'; Present = $true; State = (New-TestState -Index 5 -Alias 'Wi-Fi') }
            [pscustomobject]@{ Key = 'b'; Alias = 'Dock USB'; Present = $false; State = $null }
            [pscustomobject]@{ Key = 'c'; Alias = 'Ethernet'; Present = $true; State = (New-TestState -Index 7 -Alias 'Ethernet') }
            [pscustomobject]@{ Key = 'd'; Alias = 'Ethernet 2'; Present = $true; State = (New-TestState -Index 9 -Alias 'Ethernet 2') }
        )
        $plan = @(Get-NisPriorityPlan -Entries $entries)
    }
    It 'attribue un rang à chaque interface, absentes comprises' { ($plan | ForEach-Object { $_.Rank }) | Should -Be @(1, 2, 3, 4) }
    It 'calcule les métriques d''interface 10, 20, 30...' { $plan.InterfaceMetric | Should -Be @(10, 20, 30, 40) }
    It 'calcule les métriques de route 0, 10, 20...' { $plan.RouteMetric | Should -Be @(0, 10, 20, 30) }
    It 'produit des métriques totales strictement croissantes et espacées' {
        $plan.TotalMetric | Should -Be @(10, 30, 50, 70)
        for ($i = 1; $i -lt $plan.Count; $i++) { ($plan[$i].TotalMetric - $plan[$i - 1].TotalMetric) | Should -BeGreaterOrEqual 20 }
    }
    It 'conserve le rang d''une interface absente sans la cibler' {
        $plan[1].Present | Should -BeFalse
        $plan[1].InterfaceIndex | Should -BeNullOrEmpty
    }
    It 'gère N interfaces' {
        $many = 1..12 | ForEach-Object { [pscustomobject]@{ Key = "k$_"; Alias = "If$_"; Present = $true; State = (New-TestState -Index $_ -Alias "If$_") } }
        $p = @(Get-NisPriorityPlan -Entries $many)
        $p.Count | Should -Be 12
        $p[-1].InterfaceMetric | Should -Be 120
        $p[-1].TotalMetric | Should -Be 230
    }
    It 'renvoie un plan vide pour une liste vide' { @(Get-NisPriorityPlan -Entries @()).Count | Should -Be 0 }
}

Describe 'Move-NisListItem' {
    It 'monte un élément' { Move-NisListItem -Items @('a', 'b', 'c') -From 2 -To 1 | Should -Be @('a', 'c', 'b') }
    It 'descend un élément' { Move-NisListItem -Items @('a', 'b', 'c') -From 0 -To 2 | Should -Be @('b', 'c', 'a') }
    It 'borne la destination' { Move-NisListItem -Items @('a', 'b', 'c') -From 0 -To 99 | Should -Be @('b', 'c', 'a') }
    It 'ignore une source invalide' { Move-NisListItem -Items @('a', 'b') -From 5 -To 0 | Should -Be @('a', 'b') }
}

Describe 'Merge-NisOrder' {
    BeforeAll {
        $wifi = New-TestState -Index 5 -Alias 'Wi-Fi' -Guid '{AAA}' -Kind 'Wi-Fi' -Routes @(New-TestRoute '192.168.1.1' 0) -Metric 50
        $eth = New-TestState -Index 7 -Alias 'Ethernet' -Guid '{BBB}' -Routes @(New-TestRoute '10.0.0.1' 0) -Metric 25
        $eth2 = New-TestState -Index 9 -Alias 'Ethernet 2' -Guid '{CCC}' -Metric 5
    }
    It 'sans ordre sauvegardé, reprend la priorité actuelle de Windows (routes d''abord)' {
        $m = @(Merge-NisOrder -SavedOrder @() -States @($wifi, $eth, $eth2))
        $m.Alias | Should -Be @('Ethernet', 'Wi-Fi', 'Ethernet 2')
    }
    It 'respecte l''ordre sauvegardé et ajoute les nouvelles interfaces à la fin' {
        $saved = @([pscustomobject]@{ Alias = 'Wi-Fi'; Guid = '{AAA}'; Kind = 'Wi-Fi' })
        $m = @(Merge-NisOrder -SavedOrder $saved -States @($eth, $wifi, $eth2))
        $m.Alias | Should -Be @('Wi-Fi', 'Ethernet', 'Ethernet 2')
    }
    It 'retrouve une interface renommée grâce à son GUID' {
        $renamed = New-TestState -Index 5 -Alias 'Wi-Fi bureau' -Guid '{aaa}' -Kind 'Wi-Fi'
        $saved = @([pscustomobject]@{ Alias = 'Wi-Fi'; Guid = '{AAA}'; Kind = 'Wi-Fi' })
        $m = @(Merge-NisOrder -SavedOrder $saved -States @($renamed))
        $m[0].Present | Should -BeTrue
        $m[0].Alias | Should -Be 'Wi-Fi bureau'
    }
    It 'garde à sa place une interface absente' {
        $saved = @(
            [pscustomobject]@{ Alias = 'Ethernet'; Guid = '{BBB}'; Kind = 'Ethernet' }
            [pscustomobject]@{ Alias = 'Dock USB'; Guid = '{DDD}'; Kind = 'Ethernet' }
            [pscustomobject]@{ Alias = 'Wi-Fi'; Guid = '{AAA}'; Kind = 'Wi-Fi' }
        )
        $m = @(Merge-NisOrder -SavedOrder $saved -States @($wifi, $eth))
        $m.Alias | Should -Be @('Ethernet', 'Dock USB', 'Wi-Fi')
        $m[1].Present | Should -BeFalse
    }
    It 'ne confond pas deux cartes de même nom mais de GUID différents' {
        $saved = @([pscustomobject]@{ Alias = 'Ethernet'; Guid = '{OLD}'; Kind = 'Ethernet' })
        $m = @(Merge-NisOrder -SavedOrder $saved -States @($eth))
        $m.Count | Should -Be 2
        $m[0].Present | Should -BeFalse
        $m[1].Key | Should -Be $eth.Key
    }
    It 'avec -UsableOnly, masque une carte virtuelle sauvegardée au lieu de l''afficher absente' {
        $vm = New-TestState -Index 30 -Alias 'vEthernet (WSL)' -Guid '{VVV}' -Usable $false
        $saved = @(
            [pscustomobject]@{ Alias = 'vEthernet (WSL)'; Guid = '{VVV}' }
            [pscustomobject]@{ Alias = 'Dock USB'; Guid = '{DDD}' }
            [pscustomobject]@{ Alias = 'Wi-Fi'; Guid = '{AAA}' }
        )
        $m = @(Merge-NisOrder -SavedOrder $saved -States @($vm, $wifi) -UsableOnly)
        $m.Alias | Should -Be @('Dock USB', 'Wi-Fi')
        @(Merge-NisOrder -SavedOrder $saved -States @($vm, $wifi)).Count | Should -Be 3
    }
    It 'ignore les doublons du fichier' {
        $saved = @(
            [pscustomobject]@{ Alias = 'Wi-Fi'; Guid = '{AAA}' }
            [pscustomobject]@{ Alias = 'Wi-Fi'; Guid = '{AAA}' }
        )
        @(Merge-NisOrder -SavedOrder $saved -States @($wifi)).Count | Should -Be 1
    }
}

Describe 'ConvertTo-NisMetric' {
    It 'accepte un entier valide' { (ConvertTo-NisMetric -Text ' 42 ' -Min 1 -Max 9999).Value | Should -Be 42 }
    It 'refuse du texte' { (ConvertTo-NisMetric -Text 'abc').Error | Should -Not -BeNullOrEmpty }
    It 'refuse un nombre négatif' { (ConvertTo-NisMetric -Text '-5').Error | Should -Not -BeNullOrEmpty }
    It 'refuse un nombre hors limites' { (ConvertTo-NisMetric -Text '10000' -Max 9999).Error | Should -Match 'hors limites' }
    It 'refuse 0 pour une métrique d''interface' { (ConvertTo-NisMetric -Text '0' -Min 1).Error | Should -Not -BeNullOrEmpty }
}

Describe 'ConvertTo-NisDesiredFromInput (vue Avancé)' {
    BeforeAll { $s = New-TestState -Index 5 -Alias 'Wi-Fi' -Routes @(New-TestRoute '192.168.1.1' 0) }
    It 'métrique automatique : ignore la valeur saisie' {
        $r = ConvertTo-NisDesiredFromInput -State $s -AutomaticMetric $true -InterfaceMetricText 'nimporte' -RouteMetricText '5' -IPv6Enabled $true -IPv6MetricText ''
        $r.Errors.Count | Should -Be 0
        $r.Desired.AutomaticMetric | Should -BeTrue
        $r.Desired.InterfaceMetric | Should -BeNullOrEmpty
        $r.Desired.RouteMetric | Should -Be 5
        $r.Desired.IPv6AutomaticMetric | Should -BeTrue
    }
    It 'signale une valeur invalide' {
        $r = ConvertTo-NisDesiredFromInput -State $s -AutomaticMetric $false -InterfaceMetricText 'x' -RouteMetricText '99999'
        $r.Errors.Count | Should -Be 2
    }
    It 'métrique IPv6 manuelle' {
        $r = ConvertTo-NisDesiredFromInput -State $s -AutomaticMetric $false -InterfaceMetricText '15' -RouteMetricText '' -IPv6Enabled $true -IPv6MetricText '30'
        $r.Desired.InterfaceMetric | Should -Be 15
        $r.Desired.RouteMetric | Should -BeNullOrEmpty
        $r.Desired.IPv6AutomaticMetric | Should -BeFalse
        $r.Desired.IPv6InterfaceMetric | Should -Be 30
    }
    It 'IPv6 désactivé : ne touche pas à la métrique IPv6' {
        $r = ConvertTo-NisDesiredFromInput -State $s -AutomaticMetric $true -IPv6Enabled $false -IPv6MetricText '30'
        $r.Desired.IPv6Enabled | Should -BeFalse
        $r.Desired.IPv6AutomaticMetric | Should -BeNullOrEmpty
    }
}

Describe 'Test-NisDesiredSettings' {
    BeforeAll {
        $states = @(
            New-TestState -Index 5 -Alias 'Wi-Fi'
            New-TestState -Index 7 -Alias 'Ethernet' -HasIPv6 $false -IPv6Enabled $false
        )
    }
    It 'accepte des réglages valides' {
        $d = @(New-NisDesiredSetting -InterfaceIndex 5 -Alias 'Wi-Fi' -AutomaticMetric $false -InterfaceMetric 10 -RouteMetric 0)
        @(Test-NisDesiredSettings -Desired $d -States $states).Count | Should -Be 0
    }
    It 'refuse une interface inconnue' {
        $d = @(New-NisDesiredSetting -InterfaceIndex 99 -Alias 'Fantome' -AutomaticMetric $true)
        Test-NisDesiredSettings -Desired $d -States $states | Should -Match 'introuvable'
    }
    It 'refuse une métrique hors limites' {
        $d = @(New-NisDesiredSetting -InterfaceIndex 5 -Alias 'Wi-Fi' -AutomaticMetric $false -InterfaceMetric 20000)
        Test-NisDesiredSettings -Desired $d -States $states | Should -Match 'hors limites'
    }
    It 'refuse une métrique manuelle manquante' {
        $d = @(New-NisDesiredSetting -InterfaceIndex 5 -Alias 'Wi-Fi' -AutomaticMetric $false)
        Test-NisDesiredSettings -Desired $d -States $states | Should -Match 'manquante'
    }
    It 'refuse une métrique IPv6 sans interface IPv6' {
        $d = @(New-NisDesiredSetting -InterfaceIndex 7 -Alias 'Ethernet' -IPv6AutomaticMetric $false -IPv6InterfaceMetric 10)
        Test-NisDesiredSettings -Desired $d -States $states | Should -Match 'IPv6'
    }
    It 'refuse les doublons' {
        $d = @(
            New-NisDesiredSetting -InterfaceIndex 5 -Alias 'Wi-Fi' -AutomaticMetric $true
            New-NisDesiredSetting -InterfaceIndex 5 -Alias 'Wi-Fi' -AutomaticMetric $true
        )
        Test-NisDesiredSettings -Desired $d -States $states | Should -Match 'deux fois'
    }
    It 'valide tout le plan d''un coup (toutes les erreurs remontées)' {
        $d = @(
            New-NisDesiredSetting -InterfaceIndex 5 -Alias 'Wi-Fi' -AutomaticMetric $false -InterfaceMetric 0
            New-NisDesiredSetting -InterfaceIndex 99 -Alias 'Fantome' -AutomaticMetric $true
        )
        @(Test-NisDesiredSettings -Desired $d -States $states).Count | Should -Be 2
    }
}

Describe 'Get-NisChangeSet' {
    BeforeAll {
        $wifi = New-TestState -Index 5 -Alias 'Wi-Fi' -Auto $true -Metric 50 -Routes @(New-TestRoute '192.168.1.1' 0)
        $eth = New-TestState -Index 7 -Alias 'Ethernet' -Auto $false -Metric 20 -Routes @(New-TestRoute '10.0.0.1' 10)
        $states = @($wifi, $eth)
    }
    It 'ne produit aucune action si tout est déjà en place' {
        $d = @(New-NisDesiredSetting -InterfaceIndex 7 -Alias 'Ethernet' -AutomaticMetric $false -InterfaceMetric 20 -RouteMetric 10)
        @(Get-NisChangeSet -Desired $d -States $states).Count | Should -Be 0
    }
    It 'produit les actions de la vue Simple dans le bon ordre' {
        $plan = @(Get-NisPriorityPlan -Entries @(
                [pscustomobject]@{ Key = $wifi.Key; Alias = 'Wi-Fi'; Present = $true; State = $wifi }
                [pscustomobject]@{ Key = $eth.Key; Alias = 'Ethernet'; Present = $true; State = $eth }
            ))
        $d = @(ConvertTo-NisDesiredFromPlan -Plan $plan)
        $actions = @(Get-NisChangeSet -Desired $d -States $states)
        # Wi-Fi : auto(50) -> 10 ; Ethernet : 20 -> 20 inchangé ; route Wi-Fi 0 inchangée ; route Ethernet 10 inchangée
        $actions.Count | Should -Be 1
        $actions[0].Type | Should -Be 'IPv4Metric'
        $actions[0].To.Metric | Should -Be 10
        $actions[0].From.Automatic | Should -BeTrue
    }
    It 'mémorise la valeur d''origine des routes pour pouvoir annuler' {
        $d = @(New-NisDesiredSetting -InterfaceIndex 7 -Alias 'Ethernet' -RouteMetric 500)
        $a = @(Get-NisChangeSet -Desired $d -States $states)
        $a[0].Type | Should -Be 'RouteMetric'
        $a[0].From | Should -Be 10
        $a[0].To | Should -Be 500
        $a[0].NextHop | Should -Be '10.0.0.1'
    }
    It 'ordonne IPv4, routes, activation IPv6, métrique IPv6' {
        $off = New-TestState -Index 9 -Alias 'Eth9' -IPv6Enabled $false -HasIPv6 $true -IPv6Auto $true -Routes @(New-TestRoute '1.1.1.1' 5)
        $d = @(New-NisDesiredSetting -InterfaceIndex 9 -Alias 'Eth9' -IPv6Enabled $true -IPv6AutomaticMetric $false -IPv6InterfaceMetric 40 -RouteMetric 0 -AutomaticMetric $false -InterfaceMetric 30)
        (@(Get-NisChangeSet -Desired $d -States @($off))).Type | Should -Be @('IPv4Metric', 'RouteMetric', 'IPv6Binding', 'IPv6Metric')
    }
    It 'désactive IPv6 en dernier' {
        $d = @(
            New-NisDesiredSetting -InterfaceIndex 5 -Alias 'Wi-Fi' -IPv6Enabled $false
            New-NisDesiredSetting -InterfaceIndex 7 -Alias 'Ethernet' -AutomaticMetric $true
        )
        (@(Get-NisChangeSet -Desired $d -States $states)).Type | Should -Be @('IPv4Metric', 'IPv6Binding')
    }
    It 'le reset remet tout en automatique et les routes à 0' {
        $a = @(Get-NisChangeSet -Desired @(Get-NisResetDesired -States $states) -States $states)
        ($a | Where-Object Type -eq 'IPv4Metric').Alias | Should -Be 'Ethernet'
        ($a | Where-Object Type -eq 'RouteMetric').To | Should -Be 0
    }
    It 'le mode « une interface prioritaire » met 10+0 et 1000+1000 aux autres' {
        $d = @(Get-NisForceOneDesired -States $states -InterfaceIndex 5)
        ($d | Where-Object InterfaceIndex -eq 5).InterfaceMetric | Should -Be 10
        ($d | Where-Object InterfaceIndex -eq 7).RouteMetric | Should -Be 1000
    }
}

Describe 'Invoke-NisChangeSet (cmdlets réseau simulées)' {
    BeforeAll {
        $wifi = New-TestState -Index 5 -Alias 'Wi-Fi' -Auto $true -Metric 50 -Routes @(New-TestRoute '192.168.1.1' 0)
        $eth = New-TestState -Index 7 -Alias 'Ethernet' -Auto $true -Metric 25 -Routes @(New-TestRoute '10.0.0.1' 0)
        $states = @($wifi, $eth)
        $plan = @(Get-NisPriorityPlan -Entries @(
                [pscustomobject]@{ Key = $wifi.Key; Alias = 'Wi-Fi'; Present = $true; State = $wifi }
                [pscustomobject]@{ Key = $eth.Key; Alias = 'Ethernet'; Present = $true; State = $eth }
            ))
        $actions = @(Get-NisChangeSet -Desired @(ConvertTo-NisDesiredFromPlan -Plan $plan) -States $states)
    }
    BeforeEach {
        Mock Set-NetIPInterface { }
        Mock Get-NetRoute { [pscustomobject]@{ InterfaceIndex = $InterfaceIndex; NextHop = $NextHop; RouteMetric = 0 } }
        Mock Set-NetRoute { }
    }
    It 'applique toutes les modifications' {
        $messages = New-Object System.Collections.Generic.List[string]
        $r = Invoke-NisChangeSet -Actions $actions -Log { param($m) $messages.Add($m) }
        $r.Success | Should -BeTrue
        $r.AppliedCount | Should -Be 3
        Should -Invoke Set-NetIPInterface -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 5 -and $InterfaceMetric -eq 10 -and $AutomaticMetric -eq 'Disabled' -and $AddressFamily -eq 'IPv4' }
        Should -Invoke Set-NetIPInterface -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 7 -and $InterfaceMetric -eq 20 }
        Should -Invoke Set-NetRoute -Times 1 -Exactly -ParameterFilter { $RouteMetric -eq 10 }
        $messages.Count | Should -Be 3
        Format-NisResultReport -Result $r | Should -Be @('Wi-Fi : OK (1 modification(s))', 'Ethernet : OK (2 modification(s))')
    }
    It 'annule ce qui a déjà été fait si une modification échoue' {
        Mock Set-NetRoute { throw 'Accès refusé' }
        $r = Invoke-NisChangeSet -Actions $actions
        $r.Success | Should -BeFalse
        $r.ErrorMessage | Should -Match 'Accès refusé'
        $r.FailedAction.Type | Should -Be 'RouteMetric'
        # Les deux métriques IPv4 déjà posées sont remises en automatique
        Should -Invoke Set-NetIPInterface -Times 2 -Exactly -ParameterFilter { $AutomaticMetric -eq 'Enabled' }
        ($r.Details | Where-Object Status -eq 'RolledBack').Count | Should -Be 2
        $report = Format-NisResultReport -Result $r
        $report | Should -Contain 'Wi-Fi : modifications annulées (retour à l''état initial)'
        ($report | Where-Object { $_ -like 'Ethernet*' }) | Should -Match 'ÉCHEC - Accès refusé'
    }
    It 'signale une annulation incomplète' {
        $script:calls = 0
        Mock Set-NetIPInterface { $script:calls++; if ($AutomaticMetric -eq 'Enabled') { throw 'boom' } }
        Mock Set-NetRoute { throw 'Accès refusé' }
        $r = Invoke-NisChangeSet -Actions $actions
        $r.RollbackErrors.Count | Should -Be 2
        Format-NisResultReport -Result $r | Should -Contain 'Wi-Fi : ATTENTION - annulation incomplète, vérifiez cette interface'
    }
    It 's''arrête à la première erreur et marque la suite comme non appliquée' {
        Mock Set-NetIPInterface { throw 'non' } -ParameterFilter { $InterfaceIndex -eq 5 }
        $r = Invoke-NisChangeSet -Actions $actions
        $r.AppliedCount | Should -Be 0
        ($r.Details | Where-Object Status -eq 'Skipped').Count | Should -Be 2
        Should -Invoke Set-NetRoute -Times 0
    }
    It 'gère les modifications IPv6' {
        Mock Enable-NetAdapterBinding { }
        Mock Disable-NetAdapterBinding { }
        $a = @(
            [pscustomobject]@{ Phase = 3; Type = 'IPv6Binding'; InterfaceIndex = 5; Alias = 'Wi-Fi'; NextHop = $null; From = $false; To = $true }
            [pscustomobject]@{ Phase = 4; Type = 'IPv6Metric'; InterfaceIndex = 5; Alias = 'Wi-Fi'; NextHop = $null; From = [pscustomobject]@{ Automatic = $true; Metric = 25 }; To = [pscustomobject]@{ Automatic = $false; Metric = 15 } }
        )
        (Invoke-NisChangeSet -Actions $a).Success | Should -BeTrue
        Should -Invoke Enable-NetAdapterBinding -Times 1 -Exactly -ParameterFilter { $Name -eq 'Wi-Fi' -and $ComponentID -eq 'ms_tcpip6' }
        Should -Invoke Set-NetIPInterface -Times 1 -Exactly -ParameterFilter { $AddressFamily -eq 'IPv6' -and $InterfaceMetric -eq 15 }
    }
    It 'ne fait rien sans action' { (Invoke-NisChangeSet -Actions @()).Success | Should -BeTrue }
}

Describe 'Get-NisInterfaceStates (lecture simulée)' {
    BeforeEach {
        Mock Get-NetIPInterface {
            if ($AddressFamily -eq 'IPv4') {
                [pscustomobject]@{ InterfaceIndex = 1; InterfaceAlias = 'Loopback Pseudo-Interface 1'; AutomaticMetric = 'Enabled'; InterfaceMetric = 75; ConnectionState = 'Connected' }
                [pscustomobject]@{ InterfaceIndex = 5; InterfaceAlias = 'Wi-Fi'; AutomaticMetric = 'Disabled'; InterfaceMetric = 10; ConnectionState = 'Connected' }
                [pscustomobject]@{ InterfaceIndex = 7; InterfaceAlias = 'Ethernet'; AutomaticMetric = 'Enabled'; InterfaceMetric = 25; ConnectionState = 'Disconnected' }
                [pscustomobject]@{ InterfaceIndex = 30; InterfaceAlias = 'vEthernet (WSL)'; AutomaticMetric = 'Enabled'; InterfaceMetric = 5000; ConnectionState = 'Connected' }
            } else {
                [pscustomobject]@{ InterfaceIndex = 5; InterfaceAlias = 'Wi-Fi'; AutomaticMetric = 'Enabled'; InterfaceMetric = 45 }
            }
        }
        Mock Get-NetAdapter {
            [pscustomobject]@{ ifIndex = 5; Name = 'Wi-Fi'; InterfaceGuid = '{AAA}'; InterfaceDescription = 'Intel Wi-Fi 6'; PhysicalMediaType = 'Native 802.11'; HardwareInterface = $true; Virtual = $false; Status = 'Up' }
            [pscustomobject]@{ ifIndex = 7; Name = 'Ethernet'; InterfaceGuid = '{BBB}'; InterfaceDescription = 'Realtek GbE'; PhysicalMediaType = '802.3'; HardwareInterface = $true; Virtual = $false; Status = 'Disconnected' }
            [pscustomobject]@{ ifIndex = 30; Name = 'vEthernet (WSL)'; InterfaceGuid = '{CCC}'; InterfaceDescription = 'Hyper-V Virtual Ethernet Adapter'; PhysicalMediaType = '802.3'; HardwareInterface = $false; Virtual = $true; Status = 'Up' }
        }
        Mock Get-NetRoute {
            [pscustomobject]@{ InterfaceIndex = 5; NextHop = '192.168.1.1'; RouteMetric = 0; DestinationPrefix = '0.0.0.0/0' }
            [pscustomobject]@{ InterfaceIndex = 5; NextHop = '192.168.1.1'; RouteMetric = 0; DestinationPrefix = '0.0.0.0/0' }
        }
        Mock Get-NetIPAddress {
            [pscustomobject]@{ InterfaceIndex = 5; IPAddress = '192.168.1.20' }
            [pscustomobject]@{ InterfaceIndex = 7; IPAddress = '169.254.3.4' }
        }
        Mock Get-NetAdapterBinding {
            [pscustomobject]@{ Name = 'Wi-Fi'; Enabled = $true }
            [pscustomobject]@{ Name = 'Ethernet'; Enabled = $false }
        }
    }
    It 'ne garde que les cartes physiques par défaut, sans loopback' {
        (@(Get-NisInterfaceStates)).Alias | Should -Be @('Wi-Fi', 'Ethernet')
    }
    It 'inclut les cartes virtuelles sur demande' {
        (@(Get-NisInterfaceStates -IncludeVirtual)).Alias | Should -Be @('Wi-Fi', 'Ethernet', 'vEthernet (WSL)')
    }
    It 'calcule la métrique effective et dédoublonne les routes' {
        $w = @(Get-NisInterfaceStates) | Where-Object Alias -eq 'Wi-Fi'
        $w.Kind | Should -Be 'Wi-Fi'
        $w.Routes.Count | Should -Be 1
        $w.EffectiveMetric | Should -Be 10
        $w.AutomaticMetric | Should -BeFalse
        $w.IPv4Address | Should -Be '192.168.1.20'
        $w.IPv6Enabled | Should -BeTrue
        $w.IPv6InterfaceMetric | Should -Be 45
        $w.Key | Should -Be 'guid:{aaa}'
    }
    It 'décrit une interface déconnectée sans route' {
        $e = @(Get-NisInterfaceStates) | Where-Object Alias -eq 'Ethernet'
        $e.IsUp | Should -BeFalse
        $e.EffectiveMetric | Should -BeNullOrEmpty
        $e.HasIPv6Interface | Should -BeFalse
        $e.IPv6Enabled | Should -BeFalse
    }
    It 'n''appelle aucune commande Set-*' {
        Mock Set-NetIPInterface { }
        Mock Set-NetRoute { }
        $null = Get-NisInterfaceStates -IncludeVirtual
        Should -Invoke Set-NetIPInterface -Times 0
        Should -Invoke Set-NetRoute -Times 0
    }
    It 'trie l''ordre effectif par métrique totale' {
        $st = @(Get-NisInterfaceStates)
        (@(Get-NisEffectiveOrder -States $st)).Alias | Should -Be @('Wi-Fi')
    }
}

Describe 'Find-NisEffectiveRoute' {
    It 'renvoie l''interface choisie par Windows' {
        Mock Find-NetRoute {
            [pscustomobject]@{ IPAddress = '192.168.1.20'; InterfaceIndex = 5; InterfaceAlias = 'Wi-Fi' }
            [pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '192.168.1.1'; InterfaceIndex = 5; InterfaceAlias = 'Wi-Fi' }
        }
        $r = Find-NisEffectiveRoute
        $r.Alias | Should -Be 'Wi-Fi'
        $r.SourceAddress | Should -Be '192.168.1.20'
        $r.NextHop | Should -Be '192.168.1.1'
    }
}

Describe 'Persistance de l''ordre' {
    BeforeAll { $path = Join-Path (Join-Path $TestDrive 'sub') 'order.json' }
    It 'renvoie un ordre vide sans fichier' { @(Read-NisOrder -Path $path).Count | Should -Be 0 }
    It 'sauvegarde puis relit l''ordre (aller-retour)' {
        $entries = @(
            [pscustomobject]@{ Alias = 'Wi-Fi'; Guid = '{AAA}'; Kind = 'Wi-Fi'; Present = $true }
            [pscustomobject]@{ Alias = 'Dock USB'; Guid = ''; Kind = 'Ethernet'; Present = $false }
        )
        Save-NisOrder -Entries $entries -Path $path
        $read = @(Read-NisOrder -Path $path)
        $read.Alias | Should -Be @('Wi-Fi', 'Dock USB')
        $read[0].Guid | Should -Be '{AAA}'
        Test-Path "$path.tmp" | Should -BeFalse
    }
    It 'relit correctement une liste à un seul élément' {
        Save-NisOrder -Entries @([pscustomobject]@{ Alias = 'Wi-Fi'; Guid = '{AAA}'; Kind = 'Wi-Fi' }) -Path $path
        @(Read-NisOrder -Path $path).Count | Should -Be 1
    }
    It 'tolère un fichier corrompu' {
        Set-Content -LiteralPath $path -Value '{ pas du json'
        @(Read-NisOrder -Path $path -WarningAction SilentlyContinue).Count | Should -Be 0
    }
    It 'efface l''ordre' {
        Save-NisOrder -Entries @([pscustomobject]@{ Alias = 'Wi-Fi' }) -Path $path
        Clear-NisOrder -Path $path
        Test-Path $path | Should -BeFalse
    }
    It 'utilise %APPDATA%\network-iface-switch par défaut' {
        $old = $env:APPDATA
        try {
            $env:APPDATA = $TestDrive
            Get-NisOrderFilePath | Should -Be (Join-Path (Join-Path $TestDrive 'network-iface-switch') 'order.json')
        } finally { $env:APPDATA = $old }
    }
}
