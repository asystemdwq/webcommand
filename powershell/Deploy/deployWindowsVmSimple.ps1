<#
Copyright (c) 2012-2014 VMware, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
#>

## Author: Jerry Liu, liuj@vmware.com

Param (	
	$guestId,
	$vmName,
	$guestName = "*",
  $guestPassword=$env:defaultPassword,
	$serverAddress,
	$serverUser="root",
	$serverPassword=$env:defaultPassword,
	$datastore,
	$isoImage,
	$diskMb = "15000",
	$diskFormat = "thin",
	$memMb = "1024",
	$cpu = "1",
	$ver = "default",
	$productKey,
	$imageIndex = "1",
	$language = "en-US",	
	$staticIp = "DHCP"
)

foreach ($paramKey in $psboundparameters.keys) {
	$oldValue = $psboundparameters.item($paramKey)
	$newValue = [System.Net.WebUtility]::urldecode("$oldValue")
	set-variable -name $paramKey -value $newValue
}

. .\objects.ps1

add-pssnapin vmware.vimautomation.core -ea silentlycontinue
$if = get-netipinterface -InterfaceAlias Ethernet -AddressFamily ipv4
if ($if.count) {$if = $if[0]}
$ip = Get-NetIPAddress -ifindex $if.ifindex -AddressFamily ipv4
 
$flp_server = $ip.ipaddress
$iso_server = $ip.ipaddress
$flp_nfs_store_name = "webcommander_flp"
$iso_nfs_store_name = "webcommander_iso"
$flp_path = "/flp_image"
$iso_path = "/iso_image"
$bfiPath = "..\BFI"

## Generate VM Specification about boot order:cd, hd, net
function GenerateVMSpec {
    Param($btf1,$btf2)
    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.extraConfig += New-Object VMware.Vim.OptionValue
    $spec.extraConfig[0].key = "bios.bootDeviceClasses"
    $spec.extraConfig[0].value = "allow:$btf1,$btf2"
    return $spec
}

## Dynamiclly create new Floppy file including Answer files, installed software batch file...  
function GenerateAnswerFile{
  Param($GuestID,$VMName,$GuestName,$Esx,$ProductKey,$ImageIndex,$Language,$Dns,$staticIp,$DomainName)
	
	$FlpName = $Esx + "_" + $VMName
 	
	New-Item $BfiPath\flp_image\$FlpName -type directory | out-null
	
	if ($GuestID -eq "winXPHomeGuest" -or $GuestID -eq "winXPProGuest")
	{
		Copy-Item $BfiPath\xp_scsi_driver_x86\* $BfiPath\flp_image\$FlpName
	}
	
  if ($GuestID.StartsWith("winXP") -or $GuestID.StartsWith("winNet"))
	{
		$content = Get-Content $BfiPath\answer_file\winnt.sif
	} else {
		if ($GuestID -match "64Guest") {
			$content = Get-Content $BfiPath\answer_file\AutoUnattend_amd64.xml
		} else {
			$content = Get-Content $BfiPath\answer_file\AutoUnattend_x86.xml
		}
	}
	
	$pattern = "12345-12345-12345-12345-12345"
	$content = $content -replace $pattern, $productKey
	
	$pattern = "xx-xx"
	$content = $content -replace $pattern, $Language
	
	$pattern = "GuestName"
	$content = $content -replace $pattern, $GuestName
  
  $pattern = "GuestPassword"
	$content = $content -replace $pattern, $guestPassword
	
	$pattern = "ImageIndex"
	$content = $content -replace $pattern, $ImageIndex
	
	$content | set-content $BfiPath\flp_image\$FlpName\winnt.sif
	$content | set-content $BfiPath\flp_image\$FlpName\AutoUnattend.xml
	
	if (test-path .\batch_install.bat)
	{
		$content = Get-Content .\batch_install.bat
	} else {
		$content = get-content $BfiPath\inst_script\batch_install_simple.bat
	}
    
	$pattern = "XXXipXXX"
	$content = $content -replace $pattern, $staticIp

	$content | set-content $BfiPath\flp_image\$FlpName\batch_install.bat
  Copy-Item $BfiPath\inst_script\post_install_simple.vbs $BfiPath\flp_image\$FlpName
  Copy-Item $BfiPath\inst_script\upgrader.exe $BfiPath\flp_image\$FlpName
	
	& "$BfiPath\bfi.exe" "-f=$BfiPath\flp_image\$FlpName.flp" "$BfiPath\flp_image\$FlpName" | out-null
	rd $BfiPath\flp_image\$FlpName -force -Recurse | out-null
}

### New vms funtion
function MakeVm {
  Param ($GosId,$Name,$Esx,$datastore,$isoname,$DiskSize,$MemSize,$Cpu,$Ver,$vmspec)
		
	try {
		if ($Ver -ne "Default") {
			$vm = New-VM -Name $Name -GuestId $GosId -VMHost $Esx -Datastore $datastore `
				-DiskMB $DiskSize -DiskStorageFormat $diskFormat -MemoryMB $MemSize -NumCpu $Cpu `
				-version $ver -cd -floppy -EA Stop
		} else {
			$vm = New-VM -Name $Name -GuestId $GosId -VMHost $Esx -Datastore $datastore `
				-DiskMB $DiskSize -DiskStorageFormat $diskFormat -MemoryMB $MemSize -NumCpu $Cpu `
				-cd -floppy -EA Stop
		}
	} catch {
		writeCustomizedMsg "Fail - create new virtual machine"
		writeStderr
		[Environment]::exit("0")
	}

	while(get-task | where{$_.state -eq "Running"}){
		start-sleep 3
	}
	if ($GosId -like "win*"){		
		$FlpName = $Esx + "_" + $Name
		try {
			get-floppydrive -vm $vm | set-floppydrive -FloppyImagePath "[$flp_nfs_store_name] $FlpName.flp" `
				-confirm:$false -StartConnected:$true -EA Stop
		} catch {
			writeCustomizedMsg "Fail - create virtual floppy"
			writeStderr
			[Environment]::exit("0")
		}

		try {
			get-cddrive -vm $vm | set-cddrive -ISOPath "[$iso_nfs_store_name] $isoImage" `
				-confirm:$false -StartConnected:$true -EA Stop
		} catch {
			writeCustomizedMsg "Fail - create virtual CD of Windows ISO"
			writeStderr
			[Environment]::exit("0")
		}	
		
		while(get-task | where{$_.state -eq "Running"}){
			start-sleep 3
		}
		(get-view $vm.ID).ReconfigVM_Task($vmspec) | out-null
		
		while(get-task | where{$_.state -eq "Running"}){
			start-sleep 3
		}
		if ($GosID -match "windows8") {
			$nic = get-vm $name | get-networkadapter 
			$netName = $nic.networkname
			remove-networkadapter $nic -confirm:$false
			get-vm $name | new-networkadapter -StartConnected -type e1000 -confirm:$false -NetworkName $netName
		}
	} 
	while(get-task | where{$_.state -eq "Running"}){
		start-sleep 3
	}
    Start-VM -VM $vm -RunAsync | out-null 
}

$vmspec = GenerateVMSpec -btf1 "cd" -btf2 "hd"

try {
	$viserver = connect-VIServer $serverAddress -user $serverUser -password $serverPassword -wa 0 -EA stop
} catch {
	writeCustomizedMsg "Fail - connect to server $address"
	writeStderr
	[Environment]::exit("0")
}

Get-VMHostFirewallException -Name "NFS Client" |  Set-VMHostFirewallException -Enabled:$true
try {
	$esxcli = Get-EsxCli
	$esxcli.network.firewall.ruleset.set($true, $true, "nfsClient")
} catch {
	#writeCustomizedMsg "Info - If can not mount NFS server, please check ESX firewall settings."
}
	
if ((get-DataStore | where{$_.name -eq $iso_nfs_store_name}) -eq $null){
	try {
		$isoStore = new-datastore -nfs -name $iso_nfs_store_name -path $iso_path -nfshost $iso_server -EA Stop
	} catch {
		writeCustomizedMsg "Fail - mount NFS share of ISO images."
		writeStderr
		[Environment]::exit("0")
	}
} 	
if ((get-DataStore | where{$_.name -eq $flp_nfs_store_name}) -eq $null){
	try {
		$flpStore = new-datastore -nfs -name $flp_nfs_store_name -path $flp_path -nfshost $flp_server -EA Stop
	} catch {
		writeCustomizedMsg "Fail - mount NFS share of floppy images."
		writeStderr
		[Environment]::exit("0")
	}
} 	
	
GenerateAnswerFile $GuestID $VMName $GuestName $serverAddress $ProductKey $ImageIndex $Language $Dns $staticIp $DomainName
MakeVm $GuestID $VMName $serverAddress $datastore $isoname $DiskMB $MemMB $Cpu $Ver $vmspec
disconnect-VIServer -Server * -Force -Confirm:$false
writeCustomizedMsg "Success - VM has been created and started."