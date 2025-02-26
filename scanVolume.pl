#!/bin/env perl

use strict;                 # Always run in strict mode to avoid common pitfalls.
use warnings;
use Getopt::Long;           # Command line parsing
use Pod::Usage;             # Display help and manual
use JSON;                   # JSON parsing

use File::stat;
use User::pwent;
use File::Find;
use File::Basename;
use Cwd 'abs_path';
use gcSDEDiskAdmin;
use gcDiskAdmin;
use HTML::Template;  

#############################################################################################################
# Globals

my $sf = "/tool/sysadmin/bin/sf";
my $p4 = "/tool/pandora64/bin/p4";
my $p4Port = "atlvp4p01.amd.com:1677";

my $webserver_root = "/proj/gpg_asdc_webdata/gfxweb/stats";

my $sendmailpath="/usr/sbin/sendmail";

my @activeProjects;

my $volumeFile;
my $waiverFile = "//tools/internal/gc_infra/main/src/tools/scripts/admin/disks/data/cleaupWaivers.txt";
my $DiskOwnerFile = "//tools/internal/gc_infra/main/src/tools/scripts/admin/disks/data/disk_owners.dat";

my $findDepth = 7;
my $dormantAge = 30;

my $showValidWorkspaces;
my $showSize;
my $showL1Volum;
my $sendEmail;
my $publish;
my $dbFile;

my $db;

my @volumeList;

my %volumeInfoHash;
my %userWorksapceByDisk;

my %totalInfo;

my $help;
my $manual;

my %reclaimedDirs;

my %validWorkspaces;
my %waivedWorkspaces;

my %badWorkspaces;

my %allWorkspacesByUser;
my %allWorkspaceCountsByUser;
my %badWorkspacesByUser;
my %badWorkspaceCountsByUser;

my %userWorkspaces;
my $disabledWorkspaces;

my %allWorkspaceSizeByUserbyVolm;
my %waivedWorkspaceSizeByUserbyVolm;
my %reportsByVolumeforL1usage;

my %reportsByVolume;
my %reportsByVolume_db;

my %disk_contacts;

my $summaryPage = "graphicsDiskReview.html";

# my $summaryEmailList = "dl.gfxip.disk_monitor\@amd.com,Stuart.Lindsay\@amd.com,Ted.Wilson\@amd.com,Michael.Harris\@amd.com";
my $summaryEmailList = "Nancy.Sun\@amd.com";

my $daysBeforeArchive = 7;
my $daysBeforeDelete = 14;

my $separator = "====================================================================================================================================================================================";


#############################################################################################################
# Main Program

my $startTime = localtime();

ParseCommandLine();

if (defined $volumeFile) 
{ 
    if ($volumeFile =~ m/^\/\//) {
        push @volumeList, split /\n/,`$p4 -p $p4Port print -q $volumeFile`;
    } else {
        push @volumeList, split /\n/,`cat $volumeFile`;
    } 
} 
else 
{  
    my $diskInfo = gcDiskAdmin::GetDiskInfo($DiskOwnerFile);

    my @tagArray = qw( Verif Design Tsim Undefined);
    #my @tagArray = qw( Verif Design Tsim Undefined EMU SDEUser DISK-BU);

    my $filteredData = gcDiskAdmin::Filter($$diskInfo{data}, $$diskInfo{fields}, "Tag", \@tagArray);

    foreach my $disk_element (@$filteredData) {    
        push @volumeList, $disk_element->[20];      
    }  
}  
push @activeProjects, split /\n/,`$p4 -p $p4Port print -q //tools/internal/gc_infra/main/src/tools/scripts/admin/disks/data/activeProjects.txt`;

# Read waivers
if (defined $waiverFile)
{
    my @waiverList = split /\n/,`$p4 -p $p4Port print -q $waiverFile`;

    foreach my $waiver (@waiverList)
    {
        my @waiverFields = split /,/, $waiver;

        if (scalar @waiverFields)
        {
            $waivedWorkspaces{$waiverFields[0]} = 1;
        }       
    }
}


my @DiskOwnerList = split /\n/,`$p4 -p $p4Port print -q $DiskOwnerFile`;

foreach my $owner (@DiskOwnerList)
{
    if ($owner =~ m{^/proj/([^ ]+)\s+.*\s+([^ ]+\@amd\.com)$}) {
        my $disk_name = $1;
        $disk_contacts{$disk_name} = $2;
    }
}

$totalInfo{Volumes} = 0;
$totalInfo{WorkspaceCount} = 0;
$totalInfo{WorkspaceSize} = 0;
$totalInfo{ReclaimCount} = 0;
$totalInfo{ReclaimSize} = 0;

foreach my $volume (@volumeList)
{
    my @workspaces;
    $volume =~ s/\/proj\///g;

    unless (-d "/proj/$volume")
    {
        print "WARNING:  /proj/$volume does not exist!!  Please check the volume reference.  Skipping.\n";
        next;
    }

    $totalInfo{Volumes} += 1;

    my %volumeInfo;
    $volumeInfoHash{$volume} = \%volumeInfo;

    $volumeInfo{WorkspaceCount} = 0;
    $volumeInfo{WorkspaceSize} = 0;
    $volumeInfo{ReclaimCount} = 0;
    $volumeInfo{ReclaimSize} = 0;


    print "\n";
    print "Analyzing /proj/$volume...\n";

    my @df = split /\n/,`df -h /proj/$volume`;
    my $dfLine = $df[1];
    $dfLine =~ s/\s+/ /g;
    my @dfData = split / /,$dfLine;

    $volumeInfo{filesystem} = $dfData[0];

    if ($dfData[1] =~ m/(.*)G/)
    {
        $volumeInfo{Size} = $1 / 1000;
        $totalInfo{Size} += $volumeInfo{Size};
    }
    elsif ($dfData[1] =~ m/(.*)T/)
    {
        $volumeInfo{Size} = $1;
        $totalInfo{Size} += $volumeInfo{Size};
    }
    else
    {
        print "WARNING:  Unrecognized volume size '$dfData[1]'.\n";
        $volumeInfo{Size} = 0;
    }

    if ($dfData[2] =~ m/(.*)G/)
    {
        $volumeInfo{Used} = sprintf "%.1f", $1 / 1000;
        $totalInfo{Used} += $volumeInfo{Used};
    }
    elsif ($dfData[2] =~ m/(.*)T/)
    {
        $volumeInfo{Used} = $1;
        $totalInfo{Used} += $volumeInfo{Used};
    }
    elsif ($dfData[2] =~ m/(.*)K/)
    {
        $volumeInfo{Used} = sprintf "%.1f", $1 / 1000 / 1000;
        $totalInfo{Used} += $volumeInfo{Used};
    }
    else
    {
        print "WARNING:  Unrecognized volume used size '$dfData[2]'.\n";
        $volumeInfo{Used} = 0;
    }

    if ($dfData[3] =~ m/(.*)G/)
    {
        $volumeInfo{Avail} = sprintf "%.1f", $1 / 1000;
        $totalInfo{Avail} += $volumeInfo{Avail};
    }
    elsif ($dfData[3] =~ m/(.*)T/)
    {
        $volumeInfo{Avail} = $1;
        $totalInfo{Avail} += $volumeInfo{Avail};
    }
    elsif ($dfData[3] eq "0")
    {
        $volumeInfo{Avail} = 0;
        $totalInfo{Avail} += $volumeInfo{Avail}; 
    }
    else
    {
        print "WARNING:  Unrecognized volume available size '$dfData[3]'.\n";
        $volumeInfo{Avail} = 0;
    }

    $volumeInfo{Percent} = $dfData[4];


#-------------------------------------------get L1 subdir of a volum ----------------------------------

    if(defined $showL1Volum) {
    
        my $duLone = `/tool/sysadmin/bin/sfdu -d 1 -h ATL_gfxip:/$volume/ 2> /dev/null`;
    
        my @du_lines = split /\n/, $duLone;
    
        foreach my $loneDir (@du_lines) 
        {
            if ($loneDir =~ /([\d.]+(KiB|MiB|GiB|TiB)).*(ATL_gfxip:\/$volume\/.+$)/) 
            {
                my $leafDirSize_Unit = $1;
                my $leafDir = $3; 
    
                (my $leafRDir = $leafDir ) =~ s/ATL_gfxip:/\/proj/;
                my $L1_owner = GetOwner($leafRDir);
    
                $reportsByVolumeforL1usage{$volume}{$leafRDir} = {
                    owner       =>  "$L1_owner",
                    size        =>  "$leafDirSize_Unit",
                };
            }
        }
    }

#------------------------------------end of  L1 subdir of a volum ----------------------------------------

    print "    Finding all workspaces...\n";
   
    my $findOutput = `$sf query --name configuration_id --type f --maxdepth $findDepth ATL_gfxip:$volume 2> /dev/null`;

    my @lines = split '\n', $findOutput;

    foreach my $line (@lines)
    {
        if ($line =~ m/(\S+)\/configuration_id/)
        {
            push @workspaces, $1;
        }
    }

    UniquifyWorkspaceList(\@workspaces);

    my $bFirst = 1;

    my $processedCount;
    my $workspaceCount = scalar @workspaces;
    print "there are $workspaceCount workspaces!\n ";

    print "    Processing workspaces...\n";

    foreach my $workspace (@workspaces)
    {
        $workspace =~ s/ATL_gfxip:/\/proj\//;
        $volumeInfo{WorkspaceCount} += 1;
        $totalInfo{WorkspaceCount} += 1;

        my $codelineInfo = `cat $workspace/configuration_id 2> /dev/null`;
        chomp($codelineInfo);

        unless ($codelineInfo =~ m/(\S+)\/(\S+)@(\S+)/) { next; }

        my $codeline = $1;
        my $branch = $2;
        my $cl = $3;

        my $owner = GetOwner($workspace);

        if (exists $waivedWorkspaces{$workspace})
        {
            $validWorkspaces{$volume}{$workspace} = {  
                owner       => $owner,  
                codeline    => $codeline,  
                reason      => "waived", 
                dirSize     => undef, 
            }; 
        }
        else
        {
            my $reclaim = 0;
            my $reason;

            if (IsUserDisabled($owner))
            {
                $reclaim = 1;
                $reason = "User is no longer valid.";
            }
            elsif (IsCodelineRetired($codeline))
            {
                $reclaim = 1;
                $reason = "Not an active codeline.";
            }
            elsif (IsWorkspaceDead($workspace))
            {
                $reclaim = 1;
                $reason = "No Perforce client spec.";
            }

            my $dirSize=0;
            my $sizeTitle = "";

            if (defined $showSize)
            {
                $dirSize = GetDirectorySize($workspace);
                print "\n the size of workspace $workspace is $dirSize \n ";
                $sizeTitle = "Size";
            }

            unless (exists $allWorkspacesByUser{$owner})
            {
                my @array;
                $allWorkspacesByUser{$owner} = \@array;
                $allWorkspaceCountsByUser{$owner} = 0;
                $allWorkspaceSizeByUserbyVolm{$volume}{$owner}=0;
            }

            if (defined $showSize)
            {
                $volumeInfo{WorkspaceSize} += $dirSize;
                $allWorkspaceSizeByUserbyVolm{$volume}{$owner}+= $dirSize;
                $totalInfo{WorkspaceSize} += $dirSize;
            }

            push @{$allWorkspacesByUser{$owner}}, $workspace;
            $allWorkspaceCountsByUser{$owner} += 1;

            unless ($reclaim)
            {
                # See if anything has been modified in the last dormantAge days
                my $workspace_temp = $workspace;
                $workspace_temp =~ s/\/proj\///g;

                my $find = `$sf query ATL_gfxip:$workspace_temp --maxdepth 0 --type d --format 'mt'`;
                chomp $find;

                if ($find =~ /mt\s+(\d+)/) 
                {  
                    my $timestamp = $1;  
                    my $days_difference = (time() - $timestamp) / (60 * 60 * 24);  
  
                    if ($days_difference > $dormantAge) 
                    {  
                        $reclaim = 1;  
                        $reason = "Dormant workspace (unused in ${dormantAge}+ days)";  
                    } 
                } 
            }

            if ($reclaim)
            {
                my %workspaceInfo;

                my $key = GetUniqueKey($volume, $workspace);

                $workspaceInfo{volume} = $volume;
                $workspaceInfo{workspace} = $workspace;
                $workspaceInfo{owner} = $owner;
                $badWorkspaces{$key} = \%workspaceInfo;

                unless (exists $badWorkspacesByUser{$owner})
                {
                    my @array;
                    $badWorkspacesByUser{$owner} = \@array;
                    $badWorkspaceCountsByUser{$owner} = 0;
                }

                push @{$badWorkspacesByUser{$owner}}, $workspace;
                $badWorkspaceCountsByUser{$owner} += 1;

                if ($bFirst)
                {
                    $reportsByVolume{$volume} .= sprintf "%-15s %-80s %-20s  %-40s %-20s\n", "Owner", "Directory", "Codeline", "Reason",  $sizeTitle;
                    $reportsByVolume{$volume} .= "$separator\n";
                    $bFirst = 0;
                }

                my $msg;

                if (defined $showSize)
                {
                    $volumeInfo{ReclaimSize} += $dirSize;
                    $totalInfo{ReclaimSize} += $dirSize;
                    $msg = sprintf "%-80s %-20s %-30s %.1f GB\n", $workspace, $codeline, $reason, $dirSize;
                }
                else
                {
                    $msg = sprintf "%-80s %-20s %s\n", $workspace, $codeline, $reason;
                }
                $reportsByVolume{$volume} .= sprintf "%-15s %s", $owner, $msg;
                
                $reportsByVolume_db{$volume}{$workspace} = {
                    owner       => $owner,  
                    codeline    => $codeline,  
                    reason      => $reason,  
                    dirSize     => $dirSize, 
                };

                if (IsUserDisabled($owner))  
                { 
                    unless (defined $disabledWorkspaces) 
                    { 
                        $disabledWorkspaces = sprintf "%-15s %-80s %-20s %-40s %-20s\n", "Owner", "Directory", "Codeline", "Reason", $sizeTitle;
                        $disabledWorkspaces .= "$separator\n";
                    }
                    $disabledWorkspaces .= sprintf "%-15s %s", $owner, $msg; 
                }
                else 
                { 
                    unless (exists $userWorkspaces{$owner})
                    { 
                        $userWorkspaces{$owner} = sprintf "%-80s %-20s %-30s %-20s\n", "Directory", "Codeline", "Reason", $sizeTitle;
                        $userWorkspaces{$owner} .= "$separator\n";
                    }

                    $userWorkspaces{$owner} .= $msg; 
                }

                $volumeInfo{ReclaimCount} += 1;
                $totalInfo{ReclaimCount} += 1;
            }
            else
            {
                my $output;
                my $buffer = "";

                if (defined $showSize)
                {
                    $output = sprintf "%-15s %-80s %-30s %-30s %.1f GB", $owner, $workspace, $codeline, $buffer, $dirSize;
                }
                else
                {
                    $output = sprintf "%-15s %-80s %-30s", $owner, $workspace, $codeline;
                }

                $validWorkspaces{$volume}{$workspace} = {  
                    owner       => GetOwner($workspace),  
                    codeline    => $codeline,  
                    reason      => "active", 
                    dirSize     => $dirSize, 
                }; 
            }
        }

        $processedCount += 1;

        if (($processedCount % 10) == 0) { printf "        Processed %d out of %d workspaces (%.0f%%)\n", $processedCount, $workspaceCount, ($processedCount / $workspaceCount) * 100; }
    }

    if ($bFirst)
    {
        $reportsByVolume{$volume} .= "No workspaces that require review/deletion found.\n";
        $reportsByVolume_db{$volume} = undef;
    }

}

if ((exists $totalInfo{Size}) && ($totalInfo{Size} > 0)) {
    $totalInfo{Percent} = sprintf "%.0f%%", $totalInfo{Used} / $totalInfo{Size} * 100;
} else {
    $totalInfo{Percent} = "N/A";
}

my $endTime = localtime();

my $data = {
    startTime   => $startTime,
    endTime     => $endTime,
    totalInfo   => \%totalInfo,
    volumeInfo  => \%volumeInfoHash,
    validWorkspaces => \%validWorkspaces,
    #badWorkspaces => \%badWorkspaces,      # No idea about this Hash table
    allWorkspacesByUser => \%allWorkspacesByUser,
    allWorkspaceCountsByUser => \%allWorkspaceCountsByUser,
    badWorkspacesByUser => \%badWorkspacesByUser,
    badWorkspaceCountsByUser => \%badWorkspaceCountsByUser,
    reportsByVolume_db => \%reportsByVolume_db,
    reportsByVolumeforL1usage => \%reportsByVolumeforL1usage,
    allWorkspaceSizeByUserbyVolm => \%allWorkspaceSizeByUserbyVolm,
    disk_contacts => \%disk_contacts,
};

my $json_data = JSON->new->utf8->pretty->encode($data);

my $summaryJson = $summaryPage;  
$summaryJson = basename($summaryJson, '.html') . '.json';  

open(my $fh, '>', $summaryJson) or die "Cannot open file: $!";
print $fh $json_data;
close $fh;

WriteHtml();

print "\n";
print "Review report in $summaryPage.\n";

if (defined $publish)
{
    system ("cp $summaryPage $webserver_root/");
    system ("cp $summaryJson $webserver_root/"); 
}

my ($quota_data) = gcSDEDiskAdmin::ProcessDisks();

GetWaivedWorkspaceSize();

if (defined $sendEmail) 
{ 
    print "\nSending mail to user.\n";
    SendEmails(); 
    #CheckUsageAndNotify(500); # remind user to clean up disk when disk usage is over 500GB
}

exit 0;


#############################################################################################################
# UniquifyWorkspaceList

sub UniquifyWorkspaceList
{
    my ($arrayRef) = @_;

    my @sortedArray = sort @{$arrayRef};

    my @newArray;

    foreach my $element (@sortedArray)
    {
        my $subdirectory;

        foreach my $lastElement (@newArray)
        {
            if (index($element, "$lastElement/") != -1)
            {
                $subdirectory = $lastElement;
                last;
            }
        }

        unless (defined $subdirectory)
        {
            push @newArray, $element;
        }
    }

    undef @{$arrayRef};

    push @${arrayRef}, @newArray;
}


#############################################################################################################
# IsUserDisabled

sub IsUserDisabled
{
    my ($user) = @_;

    my $groups = `id $user`;
    chomp $groups;

    return not ($groups =~ m/\(asic\)/);
}


#############################################################################################################
# IsCodelineRetired

sub IsCodelineRetired
{
    my ($project) = @_;

    foreach my $active (@activeProjects)
    {
        if ($active eq $project)
        {
            return 0;
        }
    }

    return 1;
}


#############################################################################################################
# IsWorkspaceDead

sub IsWorkspaceDead
{
    my ($workspace) = @_;

    my $p4Config = "$workspace/P4CONFIG";

    unless (-e $p4Config) { return 1; }

    my $p4ConfigEntries = `cat $p4Config`;

    $p4ConfigEntries =~ m/P4PORT=(.*)/;
    my $p4Port = $1;

    $p4ConfigEntries =~ m/P4CLIENT=(.*)/;
    my $p4Client = $1;

    my $exists = `p4 -p $p4Port clients -e $p4Client 2>&1`;

    return (not ($exists =~ m/Client $p4Client /));
}


#############################################################################################################
# GetOwner

sub GetOwner
{
    my ($dir) = @_;

    my $modified_dir = $dir;

    $modified_dir =~ s/\/proj\///g;

    my $json_data = `$sf query ATL_gfxip:$modified_dir --maxdepth 0 --type d --json --format "username" 2> /dev/null`;
    
    if ($? != 0) 
    {  
        warn "WARNING: Command 'sf query' failed for directory '$dir'\n";  

        return GetOwnerFromLs($dir);  
    } 

    my $data = decode_json($json_data);

    if (defined $data->[0]->{username})
    {
        return $data->[0]->{username};
    } 
    else 
    {
        warn "Warning: No username found for $dir by sf query, falling back to ls command\n";

        return GetOwnerFromLs($dir);
    }
}

sub GetOwnerFromLs {  
    my ($dir) = @_;  
  
    my $ls = `ls -lda '$dir'`;  
    my @lines = split '\n', $ls;  
    my $pwd;  
  
    foreach my $line (@lines) {  
        if ($line =~ m/\S+$/) {  
            $pwd = $line;  
        }  
    }  
  
    if ($pwd =~ m/d\S+\s+\d+\s+(\S+)\s+/) {  
        my $user = $1;  
        return $user;  
    } else {  
        warn "Warning: Couldn't get owner for $dir using ls command.\n";  
        return "UNKNOWN";   
    }  
}  

#############################################################################################################
# GetUniqueKey

sub GetUniqueKey
{
    my ($volume, $workspace) = @_;

    my $key = "${volume}__${workspace}";
    $key =~ s/\//_/g;

    return $key;
}


#############################################################################################################
# ReadDatabase

sub ReadDatabase
{
    my ($dbFile) = @_;

    my %db;

    my $fh;

    unless (open ($fh, "<", $dbFile)) { return \%db; }

    foreach my $line (<$fh>)
    {
        my %dbEntry;

        my $key;

        my @fields = split ',', $line;

        foreach my $field (@fields)
        {
            if (defined $key)
            {
                $field =~ m/(.*)=(.*)/;

                $dbEntry{$1} = $2;
            }
            else
            {
                $key = $field;
            }
        }

        $db{$key} = \%dbEntry;
    }

    close $fh;
 
    return \%db;
}


#############################################################################################################
# WriteDatabase

sub WriteDatabase
{
    my ($dbFile, $db) = @_;

    my $fh;

    unless (open ($fh, ">", $dbFile)) 
    { 
        print "ERROR:  Couldn't open '$dbFile' for write!!\n";
        return 0;
    }

    foreach my $key (sort keys %{$db})
    {
        print $fh "$key";

        foreach my $element (sort keys %{$$db{$key}})
        {
            print $fh ",$element=$$db{$key}{$element}";
        }

        print $fh "\n";
    }

    close $fh;

    return 1;
}


#############################################################################################################
# WriteHtml

sub WriteHtml
{  
    open(my $fh, '>', $summaryPage) or die "Cannot open file: $!";  
      
    PrintHeader($fh);  
    PrintBody($fh); 
    PrintVolume($fh);
    PrintAllWorkspaces($fh);
    PrintBadWorkspaces($fh);
    PrintWorkspaceInfo($fh);
    PrintFooter($fh); 
      
    close $fh;  
}  
  
sub PrintHeader 
{  
    my ($fh) = @_; 

    $fh->print(qq{
<!DOCTYPE html>    
<html lang="en">    
<head>    
    <meta name="viewport" content="width=device-width, initial-scale=1">    
    <link rel="stylesheet" href="styles.css">    
    <link rel="stylesheet" href="https://cdn.datatables.net/1.10.25/css/jquery.dataTables.min.css">    
    <script type="text/javascript" src="https://code.jquery.com/jquery-3.5.1.js"></script>    
    <script type="text/javascript" src="https://cdn.datatables.net/1.10.25/js/jquery.dataTables.min.js"></script>   
    <script type="text/javascript" src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/3.4.1/chart.js"></script> 
    <style>  
        h1, h2 {  
            text-align: center;  
            margin: 10px 0;  
        }  
        .custom-table {  
            width: 100%;  
            border-collapse: collapse;  
            margin: 20px 0;  
            box-shadow: 0 4px 20px rgba(0, 0, 0, 0.5);  
            border-radius: 8px;  
            overflow: hidden;  
        }  
        .custom-table th, .custom-table td {  
            padding: 12px;  
            text-align: center;  
            border: none;  
        }  
        button {  
            background-color: #00bcd4;  
            color: white;  
            border: none;  
            padding: 10px 20px;  
            cursor: pointer;  
            border-radius: 5px;  
            transition: background-color 0.3s, transform 0.3s;  
            font-size: 16px;  
        }  
        button:hover {  
            background-color: #0097a7;  
            transform: scale(1.05);  
        }  
        #show-all {  
            display: none;  
        }  
        #loading {  
            display: none;  
            position: fixed;  
            top: 50%;  
            left: 50%;  
            transform: translate(-50%, -50%);  
            background-color: rgba(0, 0, 0, 0.7);  
            color: white;  
            padding: 20px;  
            border-radius: 5px;  
            z-index: 1000;  
        }
        .blue-text {  
            color: blue; 
            font-style: italic; 
        }
        #back-to-top {  
            position: fixed;  
            bottom: 20px;  
            right: 20px;  
            display: none;  
            background-color: #00bcd4;  
            color: white;  
            border: none;  
            padding: 10px 15px;  
            border-radius: 5px;  
            cursor: pointer;  
            transition: background-color 0.3s;  
        }  
        #back-to-top:hover {  
            background-color: #0097a7;  
        }  
    </style>   
</head> 
    }); 
}

sub PrintBody
{
    my ($fh) = @_;

    $fh->print(qq|
<body>   
    <div id="loading">Loading, please wait...</div>
    <hr> 
    <h1 style="text-align:center; font-size:48px; margin:10px">Graphics Disk Volume Monitor</h1>
    <hr><hr>    
    <h2 id="generated-time" style="text-align:center; font-size:24px; margin:10px"></h2>
    <hr>
    <button id="back-to-top">Back to Top</button>  
    <div id="data-container" style="margin: 0 15px;"></div>    
    <script type='text/javascript'>        
        function loadData(url) { 
            \$('#loading').show();           
            fetch(url)  
                .then(response => {  
                    if (!response.ok) {  
                        throw new Error('Network response was not ok');  
                    }  
                    return response.json();  
                })  
                .then(data => {  
                    \$('#loading').hide();         
                    console.log(data);             
                    \$('#generated-time').text("Generated " + data.startTime);  

    |);
}  
sub PrintVolume {  
    my ($fh) = @_;  
    
    my $show_l1_volume = defined $showL1Volum ? 1 : 0;
    my $show_valid_ws = defined $showValidWorkspaces? 1 : 0;
    $fh->print(qq| 
                let showL1Volum = $show_l1_volume;
                let showValid = $show_valid_ws;
                let volumeHtml = `<h3>Volume Summary</h3>`;          
                volumeHtml += `<table id="volume-info" class="display custom-table">              
                                 <thead>              
                                     <tr>              
                                         <th>Volume</th>              
                                         <th>Size (TB)</th>              
                                         <th>Used (TB)</th>              
                                         <th>Avail (TB)</th>              
                                         <th>% Used</th>              
                                         <th>Workspace Count</th>              
                                         <th>Workspaces to Review/Remove</th>              
                                         <th>% to Review</th>              
                                         <th>Volume Owner's Email</th>              
                                     </tr>              
                                 </thead>              
                                 <tbody>`;           
                             
                for (const volumeGroup in data.volumeInfo) {                    
                    const volumeData = data.volumeInfo[volumeGroup];                    
                    volumeHtml += '<tr>' +                    
                        '<td style="text-align:left"><b><a href="#' + volumeGroup + '">' + volumeGroup + '</a></b></td>' +                 
                        '<td>' + (volumeData.Size !== undefined ? volumeData.Size : 'N/A') + '</td>' +                    
                        '<td>' + (volumeData.Used !== undefined ? volumeData.Used : 'N/A') + '</td>' +                    
                        '<td>' + (volumeData.Avail !== undefined ? volumeData.Avail : 'N/A') + '</td>' +                    
                        '<td>' + (volumeData.Percent !== undefined ? volumeData.Percent : 'N/A') + '</td>' +                    
                        '<td>' + (volumeData.WorkspaceCount !== undefined ? volumeData.WorkspaceCount : 'N/A') + '</td>' +                    
                        '<td>' + (volumeData.ReclaimCount !== undefined ? volumeData.ReclaimCount : 'N/A') + '</td>' +                    
                        '<td>' + (volumeData.WorkspaceCount > 0 ? Math.round(volumeData.ReclaimCount / volumeData.WorkspaceCount * 100) + '%' : "0%") + '</td>' +                
                        '<td>' + (data.disk_contacts[volumeGroup] !== undefined ? data.disk_contacts[volumeGroup] : 'N/A') + '</td>' +                    
                        '</tr>';                    
                }       
    
                volumeHtml += '</tbody>';          
                volumeHtml += `<tfoot>      
                        <tr>      
                            <th style="text-align:left"><font color="blue"><b><i>Total (\${data.totalInfo.Volumes} managed volumes)</i></b></font></th>      
                            <th style="text-align:center"><font color="blue"><b><i>\${data.totalInfo.Size}</i></b></font></th>      
                            <th style="text-align:center"><font color="blue"><b><i>\${data.totalInfo.Used}</i></b></font></th>      
                            <th style="text-align:center"><font color="blue"><b><i>\${data.totalInfo.Avail}</i></b></font></th>      
                            <th style="text-align:center"><font color="blue"><b><i>\${data.totalInfo.Percent}</i></b></font></th>      
                            <th style="text-align:center"><font color="blue"><b><i>\${data.totalInfo.WorkspaceCount}</i></b></font></th>      
                            <th style="text-align:center"><font color="blue"><b><i>\${data.totalInfo.ReclaimCount}</i></b></font></th>      
                            <th style="text-align:center"><font color="blue"><b><i>\${data.totalInfo.WorkspaceCount > 0 ? Math.round( data.totalInfo.ReclaimCount / data.totalInfo.WorkspaceCount * 100) + '%' : "0%"}</i></b></font></th>      
                            <th style="text-align:center"><font color="blue"><b><i>dl.gfxip.disk_monitor\@amd.com</i></b></font></th>      
                        </tr>      
                    </tfoot>`;      
                volumeHtml += '</table>';    
    |);  
}  

sub PrintAllWorkspaces 
{
    my ($fh) = @_;

    $fh->print(qq{
                volumeHtml += `<h3>Users with 10 or More Workspaces</h3>`;      
                volumeHtml += `<table id="workspace-counts" class="display custom-table">              
                                 <thead>              
                                     <tr>              
                                         <th>User</th>              
                                         <th>Workspace Count</th>              
                                     </tr>              
                                 </thead>              
                                 <tbody>`;        

                const allWorkspaceCounts = data.allWorkspaceCountsByUser;          

                for (const user in allWorkspaceCounts) {      
                    if (allWorkspaceCounts[user] > 10) {       
                        volumeHtml += '<tr>' +          
                            '<td>' + user + '</a></td>' +          
                            '<td style="text-align:center"><a href="#' + user + '-all-ws">' + allWorkspaceCounts[user] + '</a></td>' +        
                            '</tr>';      
                    }        
                }          
                volumeHtml += '</tbody></table>';          
    });
} 
                        
sub PrintBadWorkspaces
{
    my ($fh) = @_;

    $fh->print(qq{
                volumeHtml += `<h3>Users with 5 or More Reviewable Bad Workspaces</h3>`;      
                volumeHtml += `<table id="bad-workspace-counts" class="display custom-table">              
                                 <thead>              
                                     <tr>              
                                         <th>User</th>              
                                         <th>Bad Workspace Count</th>              
                                     </tr>              
                                 </thead>              
                                 <tbody>`;        

                const badWorkspaceCounts = data.badWorkspaceCountsByUser;          

                for (const user in badWorkspaceCounts) {          
                    if (badWorkspaceCounts[user] > 5) {    
                        volumeHtml += '<tr>' +          
                            '<td>' + user + '</a></td>' +          
                            '<td style="text-align:center"><a href="#' + user + '-bad-ws">' + badWorkspaceCounts[user] + '</a></td>' +          
                            '</tr>';      
                    }        
                }          
                volumeHtml += '</tbody></table>';  
                volumeHtml += '<hr>'; 
    });
}                   
        
        
sub PrintWorkspaceInfo
{
    my ($fh) = @_;

    $fh->print(qq{
                for (const volumeGroup in data.volumeInfo) {              
                         
                    volumeHtml += `<div style="margin: 20px 0;" class="volume-group" id="\${volumeGroup}">`;  
                    volumeHtml += '<a name="' + volumeGroup + '"></a>';  
                    volumeHtml += `<h3><span class="blue-text">\${volumeGroup.toUpperCase()} Volume Summary</span></h3>`;        
                    volumeHtml += `<table id="ws-\${volumeGroup}" class="display custom-table">          
                                     <thead>          
                                         <tr>          
                                             <th>Users</th>          
                                             <th>Size of All Workspaces for User (GB)</th>          
                                         </tr>          
                                     </thead>          
                                     <tbody>`;    
                        
                    const userData = data.allWorkspaceSizeByUserbyVolm[volumeGroup];      
                            
                    for (const user in userData) {      
                        volumeHtml += '<tr>' +      
                            '<td>' + user + '</td>' +      
                            '<td>' + userData[user] + '</td>' +      
                            '</tr>';      
                    }      
    
                    volumeHtml += '</tbody></table>';      

                    if (showL1Volum)
                    {
                        volumeHtml += `<table id="cd-\${volumeGroup}" class="display custom-table">          
                                         <thead>          
                                             <tr>          
                                                 <th>Child Directories</th>          
                                                 <th>Owner</th>          
                                                 <th>Size</th>          
                                             </tr>          
                                         </thead>          
                                         <tbody>`;             

                        const volumeData = data.reportsByVolumeforL1usage[volumeGroup];     
    
                        for (const volumePath in volumeData) {              
                            const volume = volumeData[volumePath];              
                            volumeHtml += '<tr>' +              
                                '<td style="text-align:left">' + volumePath + '</td>' +              
                                '<td>' + (volume.owner || 'N/A') + '</td>' +              
                                '<td>' + (volume.size || 'N/A') + '</td>' +              
                                '</tr>';              
                        }        
          
                        volumeHtml += '</tbody></table>';      
                    }
                    volumeHtml += `<table id="rm-\${volumeGroup}" class="display custom-table">            
                                   <thead>            
                                       <tr>            
                                           <th>Workspaces to Review/Remove</th>            
                                           <th>Owner</th>            
                                           <th>Codeline</th>            
                                           <th>Size</th>            
                                           <th>Reason</th>            
                                       </tr>            
                                   </thead>            
                                   <tbody>`;       
                          
                    const volumeDataDb = data.reportsByVolume_db[volumeGroup];               
    
                    for (const volumePath in volumeDataDb) {                
                        const volume = volumeDataDb[volumePath];                
                        volumeHtml += '<tr>' +                
                            '<td style="text-align:left">' + volumePath + '</td>' +                
                            '<td>' + (volume.owner !== undefined ? volume.owner : 'N/A') + '</td>' +                
                            '<td>' + (volume.codeline !== undefined ? volume.codeline : 'N/A') + '</td>' +                
                            '<td>' + (volume.dirSize !== undefined ? volume.dirSize : 'N/A') + '</td>' +                
                            '<td>' + (volume.reason !== undefined ? volume.reason : 'N/A') + '</td>' +                
                            '</tr>';                
                    }          
          
                    volumeHtml += '</tbody></table>';  

                    if (showValid)
                    {
                        volumeHtml += `<table id="vd-\${volumeGroup}" class="display custom-table">          
                                         <thead>          
                                             <tr>          
                                                 <th>Valid Workspaces</th>          
                                                 <th>Owner</th>          
                                                 <th>Codeline</th>          
                                                 <th>Size</th>          
                                                 <th>Reason</th>          
                                             </tr>          
                                         </thead>          
                                         <tbody>`;             

                        const volumeValidData = data.validWorkspaces[volumeGroup];     
    
                        for (const volumePath in volumeValidData) {              
                            const volume = volumeValidData[volumePath]; 
                            volumeHtml += '<tr>' +                
                                '<td style="text-align:left">' + volumePath + '</td>' +                
                                '<td>' + (volume.owner !== undefined ? volume.owner : 'N/A') + '</td>' +                
                                '<td>' + (volume.codeline !== undefined ? volume.codeline : 'N/A') + '</td>' +                
                                '<td>' + (volume.dirSize !== undefined ? volume.dirSize : 'N/A') + '</td>' +                
                                '<td>' + (volume.reason !== undefined ? volume.reason : 'N/A') + '</td>' +                
                                '</tr>';                             
                        }        
          
                        volumeHtml += '</tbody></table>';      
                    }

                    volumeHtml += '</div>';        
                }        

                for (const user in data.allWorkspacesByUser) {  
                    const workspaces = data.allWorkspacesByUser[user];  
                    if (workspaces.length >= 10) {  
                        volumeHtml += `<div style="margin: 20px 0;" class="user-workspaces" id="\${user}-all-ws">`;  
                        volumeHtml += `<h3><span class="blue-text">\${user.toUpperCase()}'s Workspaces</span></h3>`;  
                        volumeHtml += `<table class="display custom-table">            
                                         <thead>            
                                             <tr>            
                                                 <th>Workspace Path</th>            
                                             </tr>          
                                         </thead>            
                                         <tbody>`;      
                        for (const workspace of workspaces) {        
                            volumeHtml += '<tr>' +        
                                '<td style="text-align:left">' + workspace + '</td>' +        
                                '</tr>';        
                        }        
                        volumeHtml += '</tbody></table>';    
                        volumeHtml += '</div>';  
                    }  
                }  

                for (const user in data.badWorkspacesByUser) {  
                    const badWorkspaces = data.badWorkspacesByUser[user];  
                    if (badWorkspaces.length >= 5) {  
                        volumeHtml += `<div style="margin: 20px 0;" class="user-bad-workspaces" id="\${user}-bad-ws">`;  
                        volumeHtml += `<h3><span class="blue-text">\${user.toUpperCase()}'s Bad Workspaces</span></h3>`;  
                        volumeHtml += `<table class="display custom-table">            
                                         <thead>            
                                             <tr>            
                                                 <th>Workspace Path</th>            
                                             </tr>          
                                         </thead>            
                                         <tbody>`;      
                        for (const badWorkspace of badWorkspaces) {        
                            volumeHtml += '<tr>' +        
                                '<td style="text-align:left">' + badWorkspace + '</td>' +        
                                '</tr>';        
                        }        
                        volumeHtml += '</tbody></table>';    
                        volumeHtml += '</div>';  
                    }  
                }  
    });
}  
                        
sub PrintFooter
{
    my ($fh) = @_;

    $fh->print(qq|
                volumeHtml += `<div style="text-align:right">         
                    <pre>    
                        Start Time: <span id="start-time">\${data.startTime}</span><br>    
                        End Time: <span id="end-time">\${data.endTime}</span><br>    
                    </pre>    
                </div>`; 

                \$('#data-container').append(volumeHtml);          
    
                \$('#volume-info').DataTable({            
                    "lengthMenu": [[25, 50, 100, -1], [25, 50, 100, "All"]],            
                });    
                  
                \$('#workspace-counts').DataTable({              
                    "lengthMenu": [[25, 50, 100, -1], [25, 50, 100, "All"]],              
                });      
      
                \$('#bad-workspace-counts').DataTable({              
                    "lengthMenu": [[25, 50, 100, -1], [25, 50, 100, "All"]],              
                });   

                \$('[id^="ws-"]').DataTable({            
                    "lengthMenu": [[25, 50, 100, -1], [25, 50, 100, "All"]],            
                });    
    
                \$('[id^="cd-"]').DataTable({            
                    "lengthMenu": [[25, 50, 100, -1], [25, 50, 100, "All"]],            
                });    
    
                \$('[id^="rm-"]').DataTable({            
                    "lengthMenu": [[25, 50, 100, -1], [25, 50, 100, "All"]],            
                });    

                \$('[id^="vd-"]').DataTable({            
                    "lengthMenu": [[25, 50, 100, -1], [25, 50, 100, "All"]],            
                });    
            })
            .catch(function(error) { console.log(error) });          
        }          
        loadData('$summaryJson');

        \$(window).scroll(function() {  
            if (\$(this).scrollTop() > 100) {   
                \$('#back-to-top').fadeIn();  
            } else {  
                \$('#back-to-top').fadeOut();  
            }  
        });  
  
        \$('#back-to-top').click(function() {  
            \$('html, body').animate({ scrollTop: 0 }, 800);   
        });  
    </script>         
</body>    
</html>  
    |);
}      
                        


#############################################################################################################
# SendEmails

sub SendEmails
{
    foreach my $user (keys %userWorkspaces)
    {
        my $email = "$user\@atlmail.amd.com";

        if ($user eq "gpu8dv") { $email = "dl.gpu8dv\@atlmail.amd.com" }
        elsif ($user eq "orlvalid") { $email = "dl.orlvalid\@amd.com" }
        elsif ($user eq "gpu8rg") { $email = "MarlboroGPGRegressionManagement\@amd.com" }
        elsif ($user eq "gfxipdv") { $email = "dl.gfxip.regression_admins.svdc\@amd.com" }

        my $opened = open(SENDMAIL, "|$sendmailpath -t");

        unless ($opened) { print "ERROR:  Couldn't connect to sendmail!!\n";  return 0; }

        print SENDMAIL "Subject: Graphics Disk Cleanup Required!\n";
        print SENDMAIL "Content-Type: text/html; charset=\"us-ascii\"\n";
        print SENDMAIL "From: Graphics Disk Monitor <dl.gfxip.disk_monitor\@amd.com>\n";
        print SENDMAIL "To: $email\n";
        # print SENDMAIL "CC: Stuart.Lindsay\@amd.com\n\n";
        print SENDMAIL "<br>";

        print SENDMAIL "You are receiving this email because you have one or more workspaces on managed graphics volumes that have been flagged as unecessary.";
        print SENDMAIL "Please review the list of workspaces below.\n";

        print SENDMAIL "<h3><font color=red>If you no longer require these workspaces please delete them ASAP.</font></h3>\n";
        print SENDMAIL "<br>\n";

        print SENDMAIL "<pre></b>";
        print SENDMAIL "$userWorkspaces{$user}";
        print SENDMAIL "</b></pre>";
    
        print SENDMAIL "<br>\n";
        print SENDMAIL "<br>\n";
        print SENDMAIL "<HR>\n";
        print SENDMAIL "<p>If you believe that a workspace in the list below is valid, or if you require special consideration to keep this data, please respond to this email and specify:\n";
        print SENDMAIL "<ul>\n";
        print SENDMAIL "<li>Which workspace(s) you want to keep.</li>\n";
        print SENDMAIL "<li>Why you need to keep that data.</li>\n";
        print SENDMAIL "<li>How long you need to keep that data.</li>\n";
        print SENDMAIL "</ul>\n";
        print SENDMAIL "</p>\n";

        close (SENDMAIL);
    }

    if (defined $disabledWorkspaces)
    {
        my $email = "nsun\@atlmail.amd.com";

        my $opened = open(SENDMAIL, "|$sendmailpath -t");

        unless ($opened) { print "ERROR:  Couldn't connect to sendmail!!\n";  return 0; }

        print SENDMAIL "Subject: Disk Space Consumed by Disabled Accounts\n";
        print SENDMAIL "Content-Type: text/html; charset=\"us-ascii\"\n";
        print SENDMAIL "From: Graphics Disk Monitor <dl.gfxip.disk_monitor\@amd.com>\n";
        print SENDMAIL "To: $email\n";
        print SENDMAIL "CC: Nancy.Sun\@amd.com\n\n";
        print SENDMAIL "<br>";

        print SENDMAIL "<HR align=left width=100\%>\n";
        print SENDMAIL "<br>";

        print SENDMAIL "<pre>";
        print SENDMAIL "$disabledWorkspaces";
        print SENDMAIL "</pre>";
    
        print SENDMAIL "<br>";
        print SENDMAIL "<HR align=left width=100\%>\n";

        close (SENDMAIL);
    }

    # Send HTML Summary

    my $opened = open(SENDMAIL, "|$sendmailpath -t");

    unless ($opened) { print "ERROR:  Couldn't connect to sendmail!!\n";  return 0; }

    print SENDMAIL "Subject: Disk Space Monitor Summary\n";
    print SENDMAIL "Content-Type: text/html; charset=\"us-ascii\"\n";
    print SENDMAIL "From: Graphics Disk Monitor <dl.gfxip.disk_monitor\@amd.com>\n";
    print SENDMAIL "To: $summaryEmailList\n";
    print SENDMAIL "<br>";

    print SENDMAIL `cat $summaryPage`;
   
    close (SENDMAIL);

    return 1;
}


#############################################################################################################
# IsServiceAccount
#

sub IsServiceAccount
{
    my ($user) = @_;

    my @response = split(/\n/, `/tool/sysadmin/scripts/query_ad -u $user -a employeetype 2>&1`);

    if ($response[0] =~ m/No entries returned/) 
    {
        return 1;
    }

    # Human user accounts have one attribute 'employeetype' with value 'Employee' or 'Contractor'
    # Service accounts have no attribute 'employeetype' or have it with the value 'S'

    my @employeeType = grep { m/^\s*employeetype: / } @response;

    if ((scalar(@employeeType) > 0) && ($employeeType[0] =~ m/^\s*employeetype:\s*Employee\s*$/)) 
    {
        return 0;
    }
    elsif ((scalar(@employeeType) > 0) && ($employeeType[0] =~ m/^\s*employeetype:\s*Contractor\s*$/)) 
    {
        return 0;
    }
    else
    {
        return 1;
    }
}

############################################################################################################
#  Check the usage of disk and send mail to notify users
sub CheckUsageAndNotify {  
    my ($size_threshold) = @_;  
  
    foreach my $type (keys %$quota_data) {  
        my @high_usage_quota_info;
        my $selected_volume;

        foreach my $quota_info (@{$quota_data->{$type}}) {  
            foreach my $volume (sort keys %allWorkspaceSizeByUserbyVolm) 
            {  
                if (exists $allWorkspaceSizeByUserbyVolm{$volume}{$type}) 
                {  
                    if (exists $waivedWorkspaceSizeByUserbyVolm{$volume}{$type}) 
                    {
                        if (($allWorkspaceSizeByUserbyVolm{$volume}{$type} - $waivedWorkspaceSizeByUserbyVolm{$volume}{$type}) > $size_threshold)
                        {  
                            push @high_usage_quota_info, $quota_info;  
                            $selected_volume = $volume;  
                            last; 
                        } 
                    }
                    else 
                    {  
                        if ($allWorkspaceSizeByUserbyVolm{$volume}{$type} > $size_threshold) 
                        {  
                            push @high_usage_quota_info, $quota_info;  
                            $selected_volume = $volume;  
                            last;  
                        }
                    }
                }
            }  
        }  

        if (@high_usage_quota_info) 
        {
            my ($file_name) = $volumeFile =~ m|([^/]+)$|;
            my ($group) = split '_', $file_name;
            gcSDEDiskAdmin::SendSdeEmails($type, \@high_usage_quota_info, $group, $selected_volume);  
        }  
    }  
}  

############################################################################################################
# Get the size of waived workspaces

sub GetWaivedWorkspaceSize {  
    my $waivedWorkspaceFile = "//tools/internal/gc_infra/main/src/tools/scripts/admin/disks/data/cleanupSDEWaivers.txt";
    
    my @waivedWorkspaces = split '\n', `$p4 -p $p4Port print -q $waiverFile`;
  
    foreach my $line (@waivedWorkspaces) 
    {
        chomp $line;

        my ($volume, $user, $dir) = split ',', $line;

        $waivedWorkspaceSizeByUserbyVolm{$volume}{$user} += GetDirectorySize($dir);
    }
}

############################################################################################################
# Get the size of directory

sub GetDirectorySize {  
    my ($workspace) = @_;  
      
    my $workspace_sfdu = $workspace;  
    $workspace_sfdu =~ s/^\/proj/ATL_gfxip:/;  
  
    my $du = `/tool/sysadmin/bin/sfdu -d 0 -h $workspace_sfdu 2> /dev/null`;  
      
    my $dirSize = 0;    
  
    if ($du =~ /([\d.]+)(KiB|MiB|GiB|TiB)/) {  
        $dirSize = $1;  
        my $unit = $2;  
  
        my %conversion = (  
            'KiB' => 1 / (1024**2),     # KiB to GiB  
            'MiB' => 1 / 1024,          # MiB to GiB  
            'GiB' => 1,                 # No conversion needed  
            'TiB' => 1024               # TiB to GiB  
        );  
  
        $dirSize *= $conversion{$unit} if exists $conversion{$unit};  
    }  
  
    return sprintf("%.2f", $dirSize > 0.001 ? $dirSize : 0);  
}  

#############################################################################################################
# ParseCommandLine

sub ParseCommandLine 
{
    # autoflush

    $|=1;

    # Parse the command line.
    # Commented out options are not implemented and have default values.

    GetOptions(
        'file|f=s'      => \$volumeFile,
        'waivers|w=s'   => \$waiverFile,
        'depth|d=s'     => \$findDepth,
        'age=s'         => \$dormantAge,
        'showValid'     => \$showValidWorkspaces,
        'showSize'      => \$showSize,
        'showL1Volum'   => \$showL1Volum,
        'summaryPage=s'   => \$summaryPage,
        'sendEmail'     => \$sendEmail,
        'publish'       => \$publish,
        'db=s'          => \$dbFile,
        'help|h'        => \$help,
        'manual|man'	=> \$manual,
    ) or pod2usage(2);

    # Display help or full documentation if requested.
    pod2usage(1) if (defined $help);
    pod2usage(-verbose => 2) if (defined $manual);

}
