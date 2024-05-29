param(
    [string] $mpesToApproveAsBase64
)

enum SourceMPEState {
    Provisioning
    PendingApproval
    AlreadyApproved
    UnrecognizedState
}

function Get-PrivateLinkServiceConnectionState ($MPEInfo) {
    $MPEResource = Get-AzResource -ResourceId $MPEInfo.resourceId
    if ($MPEResource) {
        switch ($MPEResource.ResourceType) {
            'Microsoft.StreamAnalytics/clusters/privateEndpoints' {
                Write-Output (Resolve-StreamAnalyticsConnState ($MPEResource))
            }
            'Microsoft.DataFactory/factories/managedvirtualnetworks/managedprivateendpoints' {
                Write-Output (Resolve-DataFactoryConnState ($MPEResource))
            }
            'Microsoft.Kusto/Clusters/ManagedPrivateEndpoints' {
                Write-Output ( Resolve-DataExplorerConnState ($MPEResource))
            }
            Default {
                throw [System.NotImplementedException]::new("ResourceType: [$($MPEResource.ResourceType)] is not supported.")
            }
        }
    }
}

function Resolve-DataExplorerConnState ($MPEResource) {
    switch ($MPEResource.Properties.ProvisioningState) {
        'Provisioning' {
            Write-Output [SourceMPEState]::Provisioning
        }
        'Succeeded' {
            Write-Output [SourceMPEState]::PendingApproval
            # The resource type Microsoft.Kusto/Clusters/ManagedPrivateEndpoints does not provide any details about the connection state. So the provisioning state is all we have to go by.
        }
        Default {
            Write-Output [SourceMPEState]::UnrecognizedState
        }
    }
}

function Resolve-DataFactoryConnState ($MPEResource) {
    switch ($MPEResource.Properties.ProvisioningState) {
        'Provisioning' {
            Write-Output [SourceMPEState]::Provisioning
        }
        'Succeeded' {
            switch ($MPEResource.Properties.ConnectionState.Status) {
                'Pending' {
                    Write-Output [SourceMPEState]::PendingApproval
                }
                'Approved' {
                    Write-Output [SourceMPEState]::AlreadyApproved
                }
                Default {
                    Write-Output [SourceMPEState]::UnrecognizedState
                }
            }
        }
        Default {
            Write-Output [SourceMPEState]::UnrecognizedState
        }
    }
}

function Resolve-StreamAnalyticsConnState ($MPEResource) {
    $privateLinkServiceConnectionState = $MPEResource.Properties.manualPrivateLinkServiceConnections | Select-Object -First 1 

    switch ($privateLinkServiceConnectionState.properties.privateLinkServiceConnectionState.status) {
        'PendingCreation' {  
            Write-Output [SourceMPEState]::Provisioning
        }
        'PendingCustomerApproval' {
            Write-Output [SourceMPEState]::PendingApproval
        }
        'SetUpComplete' {
            Write-Output [SourceMPEState]::AlreadyApproved
        }
        Default {
            Write-Output [SourceMPEState]::UnrecognizedState
        }
    }
}

function Get-PrivateEndpointConnection ($pecToApprove) {

    $targetResourceName = Split-Path($pecToApprove.privateLinkResourceId) -Leaf
    Write-Host 'Looking for private endpoints at the target resource: '$targetResourceName 

    $privateEndpointConnections = Get-AzPrivateEndpointConnection -PrivateLinkResourceId  $pecToApprove.privateLinkResourceId 
        
    if ($privateEndpointConnections) {
        Write-Host 'Found a total of' $privateEndpointConnections.Length 'private endpoint(s) on' $targetResourceName 

        $privateEndpointConnection = $privateEndpointConnections | Where-Object { (Split-Path($_.PrivateEndpoint.Id) -Leaf) -eq $pecToApprove.name } | Select-Object -First 1
            
        if ($null -ne $privateEndpointConnection) {
            $privateEndpointConnectionName = Split-Path($privateEndpointConnection.PrivateEndpoint.Id) -Leaf
            
            if ( $privateEndpointConnectionName -eq $pecToApprove.name ) {
                Write-Host 'Found:' $pecToApprove.name 'on' $targetResourceName 
                Write-Output $privateEndpointConnection
            }
        }
        else {
            Write-Host 'None of the private endpoints found on' $targetResourceName 'match' $pecToApprove.name
        }
    }
    else {
        Write-Host 'Did not find any private endpoints for: '$pecToApprove.privateLinkResourceId 
    }
    

}

function Approve-PrivateEndpointConnection ($pecToApprove) {

    $output = [PSCustomObject]@{
        Approved         = $false
        StatusIsTerminal = $false
    }

    $privateEndpointConnection = Get-PrivateEndpointConnection ($pecToApprove)
    if ($null -ne $privateEndpointConnection) {
        switch ($privateEndpointConnection.PrivateLinkServiceConnectionState.Status) {
            'Approved' {
                Write-Host $pecToApprove.name 'is already approved. Nothing to do.'
                $output.Approved = $true;
                $output.StatusIsTerminal = $true;
            }
            'Pending' {  
                    
                Write-Host $pecToApprove.name 'is pending approval'
                Write-Host 'Approving:' $pecToApprove.name
                $approveResult = Approve-AzPrivateEndpointConnection -ResourceId $privateEndpointConnection.Id -Description 'Auto-approved by infractucture automation'
                if ($approveResult) {
                    Write-Host 'APPROVED:' $pecToApprove.name -ForegroundColor DarkGreen -BackgroundColor White
                    $output.Approved = $true;
                    $output.StatusIsTerminal = $true;
                }
                else {
                    Write-Warning -Message "An error occured while approving: $($pecToApprove.name)."
                    $output.Approved = $false;
                    $output.StatusIsTerminal = $false;     
                }
            }
            Default {
                Write-Host $pecToApprove.name 'is'$privateEndpointConnection.PrivateLinkServiceConnectionState.Status 'and cannot be approved'
                $output.Approved = $false;
                $output.StatusIsTerminal = $true;
            }
        }
        Write-Output $output
    }
}

$mpesToApproveAsString = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($mpesToApproveAsBase64))
$mpesToApprove = $mpesToApproveAsString | ConvertFrom-Json 

$mpesToApprove | ForEach-Object {
    $_ | Add-Member -NotePropertyName "AttemptToAprove" -NotePropertyValue $true
}

$numberOfMPEsRemaining = $mpesToApprove.Length
$numberOfAttempts = 0
$maximumNumberOfAttempts = 60
$numberOfSecondsToWait = 5

while ($numberOfMPEsRemaining -gt 0 -And $numberOfAttempts -lt $maximumNumberOfAttempts) {
    $mpesToApprove | Where-Object { $_.AttemptToAprove -eq $true } | ForEach-Object {
        $mpeToApprove = $_
        
   
        Write-Host '----- Getting the status of' $mpeToApprove.name 'at the source -----'
        $privateLinkConnectionState = Get-PrivateLinkServiceConnectionState ($mpeToApprove)

        if ($privateLinkConnectionState) {
            Write-Host $mpeToApprove.name 'is in' $privateLinkConnectionState 'status at the source'
            switch ($privateLinkConnectionState) {
                [SourceMPEState]::Provisioning {  
                    Write-Host 'Placing'$mpeToApprove.name'back in the queue to be attempted later'
                    $mpeToApprove.AttemptToAprove = $true
                }
                [SourceMPEState]::PendingApproval {
                    $approvalState = Approve-PrivateEndpointConnection ($mpeToApprove)
                    $mpeToApprove.AttemptToAprove = -Not ($approvalState.StatusIsTerminal)
                }
                [SourceMPEState]::AlreadyApproved {
                    Write-Host $mpeToApprove.name'is completed, nothing to do.'
                    $mpeToApprove.AttemptToAprove = $false
                }
                Default {
                    Write-Host $mpeToApprove.name'cannot be auto-approved.'
                    $mpeToApprove.AttemptToAprove = $false

                }
            }
        }
        else {
            Write-Host $mpeToApprove 'was not found'
            $mpeToApprove.AttemptToAprove = $false
        }
    }

    $numberOfMPEsRemaining = ($mpesToApprove | Where-Object { $_.AttemptToAprove -eq $true }).Length
 
    $numberOfAttempts++  
    Write-Host 'numberOfMPEsRemaining:' $numberOfMPEsRemaining 'numberOfAttempts: '$numberOfAttempts 
    if ($numberOfMPEsRemaining -gt 0 -And $numberOfAttempts -lt $maximumNumberOfAttempts) {
        Write-Host '----------  Retrying again in' $numberOfSecondsToWait 'seconds ----------' 
        Start-Sleep -Seconds $numberOfSecondsToWait
    }
    else {
        if ($numberOfMPEsRemaining -gt 0 -And $numberOfAttempts -ge $maximumNumberOfAttempts) {
            Write-Host '---------- Reached maximum retries ----------'
        }
    }
}

if ($numberOfMPEsRemaining -le 0 ) {
    Write-Host 'All MPEs were processed'
}
