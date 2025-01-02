#!/bin/env perl

################################################################################################
# Copyright (c) 2021 Advanced Micro Devices, Inc.  All rights reserved.
################################################################################################

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

my @validWorkspaces;
my %validWorkspaces_db;
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
my %reportsByVolumeforL1usage_db;

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
    
        my @du_lines;
        @du_lines= split /\n/, $duLone;
    
         $reportsByVolumeforL1usage{$volume} = sprintf "%-80s %-30s %-15s\n", "Directory", "Owner","Size";
         $reportsByVolumeforL1usage{$volume} .= "$separator\n";
        foreach my $loneDir (@du_lines) {
            #print "----------loneDir is :$loneDir\n";
            if ($loneDir =~ /([\d.]+(KiB|MiB|GiB|TiB)).*(ATL_gfxip:\/$volume\/.+$)/) {
                my $leafDirSize_Unit = $1;# $loneDir =~ /([\d.]+)GiB/;
                #my $leafDirS_Unit= $2;
                my $leafDir = $3; #$loneDir =~ /(ATL_gfxip:\/gfx_gct_lec_user0\/.+$)/;
    
                #print "my leaf dir is: $leafDir and size is  $leafDirSize \n ";
                (my $leafRDir = $leafDir ) =~ s/ATL_gfxip:/\/proj/;
                my $L1_owner = GetOwner($leafRDir);
    
                $reportsByVolumeforL1usage{$volume} .= sprintf "%-80s %-30s  %-15s \n", $leafRDir, $L1_owner, $leafDirSize_Unit;
                
                $reportsByVolumeforL1usage_db{$volume}{$leafRDir} = {
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
            my $output = sprintf "%-15s %-80s %-30s", $owner, $workspace, $codeline;
            push @validWorkspaces, $output;

            $validWorkspaces_db{$volume}{$workspace} = {  
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

                push @validWorkspaces, $output;
                
                $validWorkspaces_db{$volume}{$workspace} = {  
                    owner       => GetOwner($workspace),  
                    codeline    => $codeline,  
                    reason      => "", 
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

    if (defined $showValidWorkspaces)
    {
        $reportsByVolume{$volume} .= "\n";
        $reportsByVolume{$volume} .= "$separator\n";
        $reportsByVolume{$volume} .= "\n <h5>Valid Workspaces on $volume</h5>\n";
        $reportsByVolume{$volume} .= "\n";
        
        if (defined $showSize) {
        $reportsByVolume{$volume} .= sprintf "%-15s %-80s %-40s %-10s\n", "Owner", "Directory", "Codeline","Size";
        } else {
         $reportsByVolume{$volume} .= sprintf "%-15s %-80s %s\n", "Owner", "Directory", "Codeline";
        }
        $reportsByVolume{$volume} .= "$separator\n";

        foreach my $workspace (@validWorkspaces)
        {
            $reportsByVolume{$volume} .= "$workspace\n";
        }
    }
}

if ((exists $totalInfo{Size}) && ($totalInfo{Size} > 0)) {
    $totalInfo{Percent} = sprintf "%.0f%%", $totalInfo{Used} / $totalInfo{Size} * 100;
} else {
    $totalInfo{Percent} = "N/A";
}

#foreach my $user (keys %badWorkspacesByUser) {
#    print "User: $user\n";
#    print "the Bad Workspaces:\n";
#    foreach my $workspace (@{$badWorkspacesByUser{$user}}) {
#        print "  - $workspace\n";
#    }
#}

my $endTime = localtime();

if (defined $dbFile)
{
    $db = ReadDatabase($dbFile);

    foreach my $key (keys %badWorkspaces)
    {
        unless (exists $$db{$key})
        {
            my %dbElement;

            foreach my $element (keys %{$badWorkspaces{$key}})
            {
                $dbElement{$element} = $badWorkspaces{$key}{$element};
            }

            $dbElement{flagged} = time();

            $$db{$key} = \%dbElement;
        }
    }

    # Check for workspaces that are about to be archived

    # Check for workspaces that are about to be deleted

    WriteDatabase($dbFile, $db);
}

WriteHtml();

print "\n";
print "Review report in $summaryPage.\n";

if (defined $publish)
{
    system ("cp $summaryPage $webserver_root/");
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
#############################################################################################################
# Write new html
sub WriteHtml {  
    open(my $fh, '>', $summaryPage) or die "Cannot open file: $!";  
      
    print_header($fh);  
    print_body($fh);  
      
    close $fh;  
}  
  
sub print_header {  
    my ($fh) = @_;  
    
    print $fh "<!DOCTYPE html>\n";
    print $fh "<html lang=\"en\">\n";
    print $fh "<head>\n";  
    print $fh "    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n";  

    print $fh "    <link rel=\"stylesheet\" href=\"styles.css\">\n";
    print $fh "    <link rel=\"stylesheet\" href=\"https://cdn.datatables.net/1.10.25/css/jquery.dataTables.min.css\">\n"; 
    print $fh "    <script type=\"text/javascript\" src=\"https://cdnjs.cloudflare.com/ajax/libs/Chart.js/3.4.1/chart.js\"></script>\n";
    print $fh "    <script type=\"text/javascript\" src=\"https://code.jquery.com/jquery-3.5.1.js\"></script>\n";  
    print $fh "    <script type=\"text/javascript\" src=\"https://cdn.datatables.net/1.10.25/js/jquery.dataTables.min.js\"></script>\n";  
    print $fh "    <script type=\"text/javascript\">\n";  
    print $fh "        \$(document).ready(function() {\n";
    foreach my $volume (sort keys %volumeInfoHash) {  
        push @volumeList, $volume;
    }  

    my %seen;  
    @volumeList = grep { !$seen{$_}++ } @volumeList;  
  
    print @volumeList; 
    print $fh "            var tableIds = [ 'volumes'"; 
    print $fh "," . join(", ", map { "'size-$_'" } @volumeList);
    print $fh "," . join(", ", map { "'l1volumes-$_'" } @volumeList);
    print $fh "," . join(", ", map { "'rm-ws-$_'" } @volumeList);
    print $fh "," . join(", ", map { "'vd-ws-$_'" } @volumeList);
    print $fh "];\n";
    print $fh "            tableIds.forEach(function(tableId) {\n";
    print $fh "                \$('#' + tableId).DataTable({\n";  
    print $fh "                \"lengthMenu\": [[25, 50, 100, -1], [25, 50, 100, \"All\"]],\n";  
    print $fh "            });\n";  
    print $fh "         });\n"; 
    print $fh "    });\n";  


    # toggle visibility
    print $fh "    function toggleVisibility(contentId) {\n";    
    print $fh "        var content = document.getElementById(contentId);\n";  
    print $fh "        var icon = content.previousElementSibling.querySelector('.toggle-icon');\n";  
    print $fh "        if (content.style.display === \"none\") {\n";    
    print $fh "            content.style.display = \"block\";  // Show the content\n"; 
    print $fh "            icon.textContent = '-'; // Change icon to minus\n";    
    print $fh "        } else {\n";    
    print $fh "            content.style.display = \"none\";  // Hide the content\n";
    print $fh "            icon.textContent = '+'; // Change icon to plus\n";     
    print $fh "        }\n";    
    print $fh "    }\n"; 

    print $fh "    </script>\n"; 

    print_user_usage_scripts($fh); 

    print $fh "</head>\n";  
}  
  
sub print_user_usage_scripts {  
    my ($fh) = @_;  
  
    my @usersData;  
  
    foreach my $user (sort { $badWorkspaceCountsByUser{$b} <=> $badWorkspaceCountsByUser{$a} } keys %badWorkspaceCountsByUser) {  
        next if IsServiceAccount($user);  # Don't report service accounts  
        last if $badWorkspaceCountsByUser{$user} < 5;  
  
        push @usersData, {  
            name => $user,  
            bad_workspaces => $badWorkspaceCountsByUser{$user},  
            link => "#${user}_bad_workspaces"  
        };  
    }  
  
    print $fh "    <script type=\"text/javascript\">\n"; 
    print $fh "    var ctx = document.addEventListener('DOMContentLoaded', function() {\n"; 
    print $fh "        var usersData = [\n";  
  
    foreach my $user (@usersData) {  
        print $fh "            { name: '$user->{name}', bad_workspaces: $user->{bad_workspaces}, link: '$user->{link}' },\n";  
    }  
  
    print $fh "        ];\n\n";  
  
    print $fh "        var users = usersData.map(user => user.name);\n";  
    print $fh "        var badWorkspacesToReview = usersData.map(user => user.bad_workspaces);\n";  
    print $fh "        var userLinks = usersData.map(user => user.link);\n\n";  
  
    print $fh "        var usageByCategory = createBarChart('usageByCategory', 'Workspaces to Review by User', users, badWorkspacesToReview);\n";  
      
    my @excessiveUsersData;  
    foreach my $user (sort { $allWorkspaceCountsByUser{$b} <=> $allWorkspaceCountsByUser{$a} } keys %allWorkspaceCountsByUser) {  
        next if IsServiceAccount($user);  # Don't report service accounts  
        last if $allWorkspaceCountsByUser{$user} < 10;  
  
        push @excessiveUsersData, {  
            name => $user,  
            total_workspaces => $allWorkspaceCountsByUser{$user},  
            link => "#${user}_all_workspaces"  
        };  
    }  
  
    print $fh "        var excessiveUsersData = [\n";  
    foreach my $user (@excessiveUsersData) {  
        print $fh "            { name: '$user->{name}', total_workspaces: $user->{total_workspaces}, link: '$user->{link}' },\n";  
    }  
    print $fh "        ];\n\n";  
  
    print $fh "        var excessiveUsers = excessiveUsersData.map(user => user.name);\n";  
    print $fh "        var totalWorkspaces = excessiveUsersData.map(user => user.total_workspaces);\n\n";  
  
    print $fh "        var excessiveWorkspacesChart = createBarChart('excessiveWorkspacesChart', 'Users with Excessive Workspaces', excessiveUsers, totalWorkspaces);\n";  
  
    print $fh "        function createBarChart(canvasId, title, labels, data) {\n";  
    print $fh "            var ctx = document.getElementById(canvasId).getContext('2d');\n";  
    print $fh "            var background = ctx.createLinearGradient(0, 0, 0, ctx.canvas.clientHeight);\n";  
    print $fh "            background.addColorStop(0, 'red'); \n";  
    print $fh "            background.addColorStop(0.5, 'yellow'); \n";  
    print $fh "            background.addColorStop(1, 'green'); \n\n";  
  
    print $fh "            var chart = new Chart(ctx, {\n";  
    print $fh "                type: 'bar',\n";  
    print $fh "                data: {\n";  
    print $fh "                    labels: labels,\n";  
    print $fh "                    datasets: [{\n";  
    print $fh "                        data: data,\n";  
    print $fh "                        backgroundColor: background,\n";  
    print $fh "                        borderWidth: 1\n";  
    print $fh "                    }]\n";  
    print $fh "                },\n";  
    print $fh "                options: {\n";  
    print $fh "                    plugins: {\n";  
    print $fh "                        title: {\n";  
    print $fh "                            display: true,\n";  
    print $fh "                            text: title\n";  
    print $fh "                        },\n";  
    print $fh "                        legend: {\n";  
    print $fh "                            display: false\n";  
    print $fh "                        },\n";  
    print $fh "                    },\n";  
    print $fh "                    scales: {\n";  
    print $fh "                        y: {\n";  
    print $fh "                            beginAtZero: true\n";  
    print $fh "                        }\n";  
    print $fh "                    }\n";  
    print $fh "                }\n";  
    print $fh "            });\n";  
    print $fh "            return chart;\n";
    print $fh "        }\n\n";  
  
    print $fh "        var categoryCtx = document.getElementById('usageByCategory').getContext('2d');\n";  
    print $fh "        categoryCtx.canvas.onclick = function(event) {\n";  
    print $fh "            var activePoints = usageByCategory.getElementsAtEventForMode(event, 'nearest', { intersect: true }, false);\n";  
    print $fh "            if (activePoints.length) {\n";  
    print $fh "                var clickedIndex = activePoints[0].index;\n";  
    print $fh "                var link = userLinks[clickedIndex];\n";  
    print $fh "                if (link) {\n"; 
    print $fh "                    var userName = users[clickedIndex];\n";
    print $fh "                    var contentId = 'content-' + userName;\n";
    print $fh "                    toggleVisibility('outer-content');\n";
    print $fh "                    toggleVisibility(contentId);\n";
    print $fh "                    window.location.href = link;\n";  
    print $fh "                }\n";  
    print $fh "            }\n";  
    print $fh "        };\n";  
    
    print $fh "        var excessiveCtx = document.getElementById('excessiveWorkspacesChart').getContext('2d');\n";    
    print $fh "        excessiveCtx.canvas.onclick = function(event) {\n";    
    print $fh "            var activePoints = excessiveWorkspacesChart.getElementsAtEventForMode(event, 'nearest', { intersect: true }, false);\n";    
    print $fh "            if (activePoints.length) {\n";    
    print $fh "                var clickedIndex = activePoints[0].index;\n";    
    print $fh "                var link = excessiveUsersData[clickedIndex].link;\n";    
    print $fh "                if (link) {\n";   
    print $fh "                    var excuserName = excessiveUsers[clickedIndex];\n";
    print $fh "                    var excontentId = 'content-all-' + excuserName;\n";
    print $fh "                    toggleVisibility('all-outer-content');\n"; 
    print $fh "                    toggleVisibility(excontentId);\n"; 
    print $fh "                    window.location.href = link;\n";    
    print $fh "                }\n";    
    print $fh "            }\n";    
    print $fh "        };\n"; 
    print $fh "    });\n";   

    print $fh "    </script>\n";  
}  

sub print_body {  
    my ($fh) = @_;  

    print $fh "<body>\n";
    print $fh "<hr>\n";
    print $fh "<h1 style=\"text-align:center; font-size:48px; margin:10px\">Graphics Disk Volume Monitor</h1>\n";
    print $fh "<hr>\n";
    print $fh "<hr>\n";
    print $fh "<h2 style=\"text-align:center; font-size:24px; margin:10px\">Generated " . localtime(). "</h2>\n";
    print $fh "<h4 style=\"text-align:center; margin:10px\">NOTE:  The latest report is always available <a href=\"http://atlweb01.amd.com/gfxweb/stats/graphicsDiskReview.html\">here</a>.</h4>\n";
    print $fh "<hr>\n";
    
    #print_search_box($fh);
    print_volume_summary($fh);  
    print_user_usage_summary($fh);  
    print_workspaces_to_review($fh); 
    print_user_bad_workspaces($fh);
    print_user_all_workspaces($fh);
    print_footer($fh);
}  

sub print_search_box {  
    my ($fh) = @_;  
    print $fh "<div style=\"text-align:center; margin: 20px;\">\n";  
    print $fh "    <input type=\"text\" id=\"searchDisk\" placeholder=\"Search for a disk...\" style=\"width: 300px; padding: 10px;\">\n";  
    print $fh "</div>\n";  
}  

sub print_volume_summary {  
    my ($fh) = @_;  
      
    print $fh "<div style=\"margin: 0 15px\">\n";  
    print $fh "    <h3>Volume Summary</h3><br>\n";  
    print $fh "    <div style=\"margin: 0 15px\">\n";  
    print $fh "        <table id=\"volumes\" class=\"display\" width=\"100%\">\n";  
    print $fh "            <thead>\n";  
    print $fh "                <tr>\n";  
    print $fh "                    <th style=\"text-align:left\" width=\"28%\">Volume</th>\n";  
    print $fh "                    <th style=\"text-align:center\" width=\"10%\">Size (TB)</th>\n";  
    print $fh "                    <th style=\"text-align:center\" width=\"10%\">Used (TB)</th>\n";  
    print $fh "                    <th style=\"text-align:center\" width=\"10%\">Avail (TB)</th>\n";  
    print $fh "                    <th style=\"text-align:center\" width=\"10%\">% Used</th>\n";  
    print $fh "                    <th style=\"text-align:center\" width=\"10%\">Workspace Count</th>\n";  
    print $fh "                    <th style=\"text-align:center\" width=\"12%\">Workspaces to Review/Remove</th>\n";  
    print $fh "                    <th style=\"text-align:center\" width=\"10%\">% to Review</th>\n";  
    print $fh "                    <th style=\"text-align:center\" width=\"10%\">Volume Owner's Email</th>\n";  
    print $fh "                </tr>\n";  
    print $fh "            </thead>\n";  
    print $fh "            <tbody>\n";  
  
    foreach my $volume (sort keys %volumeInfoHash) {  
        print_volume_row($fh, $volume);  
    }  
  
    print $fh "            </tbody>\n";  
    print $fh "            <tfoot>\n";  
    print $fh "                <tr>\n";  
    print $fh "                    <th style=\"text-align:left\"><font color=blue><b><i>Total ($totalInfo{Volumes} managed volumes)</font></b></i></th>\n";  
    print $fh "                    <th style=\"text-align:center\"><font color=blue><b><i>$totalInfo{Size}</font></i></b></th>\n";  
    print $fh "                    <th style=\"text-align:center\"><font color=blue><b><i>$totalInfo{Used}</font></i></b></th>\n";  
    print $fh "                    <th style=\"text-align:center\"><font color=blue><b><i>$totalInfo{Avail}</font></i></b></th>\n";  
    print $fh "                    <th style=\"text-align:center\"><font color=blue><b><i>$totalInfo{Percent}</font></i></b></th>\n";  
    print $fh "                    <th style=\"text-align:center\"><font color=blue><b><i>$totalInfo{WorkspaceCount}</font></b></i></th>\n";  
    print $fh "                    <th style=\"text-align:center\"><font color=blue><b><i>$totalInfo{ReclaimCount}</font></b></i></th>\n";  
  
    my $total_reclaim_percentage = $totalInfo{WorkspaceCount} > 0  
        ? sprintf("%.0f%%", $totalInfo{ReclaimCount} / $totalInfo{WorkspaceCount} * 100)  
        : "0%";  
    print $fh "                    <th style=\"text-align:center\"><font color=blue><b><i>$total_reclaim_percentage</font></b></i></th>\n";  
    print $fh "                    <th style=\"text-align:center\"><font color=blue><b><i>dl.gfxip.disk_monitor\@amd.com</font></b></i></th>\n";  
    print $fh "                </tr>\n";  
    print $fh "            </tfoot>\n";  
    print $fh "        </table>\n";  
    print $fh "    </div>\n";  
    print $fh "<hr>\n";  
    print $fh "</div>\n<br>\n";  
}  
  
sub print_volume_row {  
    my ($fh, $volume) = @_;  
      
    print $fh "                <tr class=\"volume-$volume\">\n"; 
    print $fh "                    <td style=\"text-align:left\"><b><a href=\"#${volume}\" onclick=\"toggleVisibility('content-$volume')\">/proj/$volume</b></td>\n";  
    print $fh "                    <td style=\"text-align:center\">$volumeInfoHash{$volume}{Size}</td>\n";  
    print $fh "                    <td style=\"text-align:center\">$volumeInfoHash{$volume}{Used}</td>\n";  
    print $fh "                    <td style=\"text-align:center\">$volumeInfoHash{$volume}{Avail}</td>\n";  
    print $fh "                    <td style=\"text-align:center\">$volumeInfoHash{$volume}{Percent}</td>\n";  
    print $fh "                    <td style=\"text-align:center\">$volumeInfoHash{$volume}{WorkspaceCount}</td>\n";  
    print $fh "                    <td style=\"text-align:center\">$volumeInfoHash{$volume}{ReclaimCount}</td>\n";  
  
    my $reclaim_percentage = $volumeInfoHash{$volume}{WorkspaceCount} > 0  
        ? sprintf("%.0f%%", $volumeInfoHash{$volume}{ReclaimCount} / $volumeInfoHash{$volume}{WorkspaceCount} * 100)  
        : "0%";  
    print $fh "                    <td style=\"text-align:center\">$reclaim_percentage</td>\n"; 
    
    my $contact_info = exists $disk_contacts{$volume} ? $disk_contacts{$volume} : "N/A";
    print $fh "                    <td style=\"text-align:center\">$contact_info</td>\n";

    print $fh "                </tr>\n";  
}  
  
sub print_user_usage_summary {    
    my ($fh) = @_;    
        
    print $fh "<div class=\"workspace-report\" style=\"margin: 0 15px\">\n";
    print $fh "    <canvas id=\"usageByCategory\" style=\"width: 100% !important; height: 400px !important;\"></canvas>\n";
    print $fh "    <canvas id=\"excessiveWorkspacesChart\" style=\"width: 100% !important; height: 400px !important;\"></canvas>\n";
    print $fh "<hr>\n";
    print $fh "</div>\n";
}

sub print_workspaces_to_review {      
    my ($fh) = @_;      
      
    print $fh "<div style=\"margin: 0 15px\">\n";      
    print $fh "    <h3>Workspaces to Review/Remove</h3>\n";      
      
    foreach my $volume (sort keys %reportsByVolume_db) {      
        print $fh "    <div class=\"volume-title\" style=\"margin: 0 15px\">\n";   
        print $fh "    <a name=\"$volume\">\n";     
        print $fh "        <div class=\"collapsible-header volume-$volume\" style=\"cursor: pointer;\" onclick=\"toggleVisibility('content-$volume')\">\n";
        print $fh "        <span class=\"toggle-icon\">+</span>Detailed Information for Volume: $volume\n";      
        print $fh "        </div>\n"; 
        print $fh "        <div id=\"content-$volume\" style=\"display: none;\">\n";  # Initially hidden    
      
        print_workspace_size_summary($fh, $volume);      
      
        if (defined $showL1Volum) {      
            print_l1_table($fh, $volume);      
        }      
      
        print_workspace_table($fh, $volume);      
      
        if (defined $showValidWorkspaces) {      
            print_valid_workspaces($fh, $volume);      
        }      
      
        print $fh "        </div>\n";  # Close content div      
        print $fh "    </div>\n";  # Close volume-title div      
    }      
      
    print $fh "</div>\n";  # Close main div      
}      
  
sub print_workspace_size_summary {      
    my ($fh, $volume) = @_;      

    if (exists $allWorkspaceSizeByUserbyVolm{$volume} && keys %{$allWorkspaceSizeByUserbyVolm{$volume}}) 
    {        
        print $fh "    <table id=\"size-$volume\" class=\"volume-$volume\" width=\"100%\">\n";      
        print $fh "        <thead>\n";      
        print $fh "            <tr>\n";      
        print $fh "                <th style=\"text-align:center\" width=\"30%\">Users</th>\n";      
        print $fh "                <th style=\"text-align:center\" width=\"30%\">Size of All Workspaces for User (GB) on $volume</th>\n";      
        print $fh "            </tr>\n";      
        print $fh "        </thead>\n";      
        print $fh "        <tbody>\n";      

        foreach my $user (keys %{$allWorkspaceSizeByUserbyVolm{$volume}}) {      
            print $fh "            <tr>\n";      
            print $fh "                <td style=\"text-align:center\"><b>$user</b></td>\n";      
            print $fh "                <td style=\"text-align:center\">$allWorkspaceSizeByUserbyVolm{$volume}{$user}</td>\n";      
            print $fh "            </tr>\n";      
        }      

        print $fh "        </tbody>\n";      
        print $fh "    </table>\n";      
        print $fh "    <br class=\"volume-$volume\">\n";    
    } else 
    {
        return 0;
    }
}     
  
sub print_l1_table {      
    my ($fh, $volume) = @_;      
      
    print $fh "<table id=\"l1volumes-$volume\" class=\"volume-$volume\" style=\"width: 100%; border-collapse: collapse;\">\n";      
    print $fh "    <thead>\n";      
    print $fh "        <tr>\n";      
    print $fh "            <th style=\"text-align:left; border: 1px solid #ddd; padding: 8px;\">L1 Directory of $volume</th>\n";      
    print $fh "            <th style=\"text-align:left; border: 1px solid #ddd; padding: 8px;\">Owner</th>\n";      
    print $fh "            <th style=\"text-align:left; border: 1px solid #ddd; padding: 8px;\">Size</th>\n";      
    print $fh "        </tr>\n";      
    print $fh "    </thead>\n";      
    print $fh "    <tbody>\n";      
      
    foreach my $l1volume (sort keys %{$reportsByVolumeforL1usage_db{$volume}}) {      
        my $owner = $reportsByVolumeforL1usage_db{$volume}{$l1volume}{owner};      
        my $size  = $reportsByVolumeforL1usage_db{$volume}{$l1volume}{size};      
      
        print $fh "        <tr>\n";      
        print $fh "            <td style=\"text-align:left; border: 1px solid #ddd; padding: 8px;\">$l1volume</td>\n";      
        print $fh "            <td style=\"text-align:left; border: 1px solid #ddd; padding: 8px;\">$owner</td>\n";      
        print $fh "            <td style=\"text-align:left; border: 1px solid #ddd; padding: 8px;\">$size</td>\n";      
        print $fh "        </tr>\n";      
    }      
      
    print $fh "    </tbody>\n";      
    print $fh "</table>\n<br class=\"volume-$volume\">\n";      
}      
      
sub print_workspace_table {      
    my ($fh, $volume) = @_;      

    if (exists $reportsByVolume_db{$volume} && keys %{$reportsByVolume_db{$volume}}) 
    {    
        print $fh "<table id=\"rm-ws-$volume\" class=\"volume-$volume\" style=\"width: 100%; border-collapse: collapse;\">\n";      
        print $fh "    <thead>\n";      
        print $fh "        <tr>\n";      
        print $fh "            <th style=\"border: 1px solid #ddd; padding: 8px;\">Workspace to Review/Remove on $volume</th>\n";      
        print $fh "            <th style=\"border: 1px solid #ddd; padding: 8px;\">Owner</th>\n";      
        print $fh "            <th style=\"border: 1px solid #ddd; padding: 8px;\">Codeline</th>\n";      
        print $fh "            <th style=\"border: 1px solid #ddd; padding: 8px;\">Directory Size (GB)</th>\n";      
        print $fh "            <th style=\"border: 1px solid #ddd; padding: 8px;\">Reason</th>\n";      
        print $fh "        </tr>\n";      
        print $fh "    </thead>\n";      
        print $fh "    <tbody>\n";      

        foreach my $workspace (keys %{$reportsByVolume_db{$volume}}) {      
            my $info = $reportsByVolume_db{$volume}{$workspace};      

            print $fh "        <tr class=\"volume-$volume\">\n";      
            print $fh "            <td style=\"border: 1px solid #ddd; padding: 8px;\">$workspace</td>\n";      
            print $fh "            <td style=\"border: 1px solid #ddd; padding: 8px;\">$info->{owner}</td>\n";      
            print $fh "            <td style=\"border: 1px solid #ddd; padding: 8px;\">$info->{codeline}</td>\n";      
            print $fh "            <td style=\"border: 1px solid #ddd; padding: 8px;\">$info->{dirSize} GB</td>\n";      
            print $fh "            <td style=\"border: 1px solid #ddd; padding: 8px;\">$info->{reason}</td>\n";      
            print $fh "        </tr>\n";      
        }      

        print $fh "    </tbody>\n";      
        print $fh "</table>\n<br class=\"volume-$volume\">\n";   
    }
    else
    {
        print $fh "    <div class=\"alert alert-warning volume-$volume\" style=\"width: 100%; border-collapse: collapse;\">\n";  
        print $fh "        <strong>Notice:</strong> No workspaces found for volume: <strong>$volume</strong>.\n";  
        print $fh "    </div>\n";  
    }   
}      
      
sub print_valid_workspaces {      
    my ($fh, $volume) = @_;      
      
    foreach my $valid_volume (sort keys %validWorkspaces_db) {      
        next unless $valid_volume eq $volume;      
      
        print $fh "        <table id=\"vd-ws-$volume\" class=\"volume-$valid_volume\" style=\"width: 100%; border-collapse: collapse;\">\n";      
        print $fh "            <thead>\n";      
        print $fh "                <tr>\n";      
        print $fh "                    <th style=\"border: 1px solid #ddd; padding: 8px;\">Valid Workspaces on $valid_volume</th>\n";      
        print $fh "                    <th style=\"border: 1px solid #ddd; padding: 8px;\">Owner</th>\n";      
        print $fh "                    <th style=\"border: 1px solid #ddd; padding: 8px;\">Codeline</th>\n";      
        print $fh "                    <th style=\"border: 1px solid #ddd; padding: 8px;\">Directory Size (GB)</th>\n";      
        print $fh "                    <th style=\"border: 1px solid #ddd; padding: 8px;\">Reason</th>\n";      
        print $fh "                </tr>\n";      
        print $fh "            </thead>\n";      
        print $fh "            <tbody>\n";      
      
        foreach my $workspace (keys %{$validWorkspaces_db{$valid_volume}}) {      
            my $info = $validWorkspaces_db{$valid_volume}{$workspace};      
      
            print $fh "                <tr class=\"volume-$valid_volume\">\n";      
            print $fh "                    <td style=\"border: 1px solid #ddd; padding: 8px;\">$workspace</td>\n";      
            print $fh "                    <td style=\"border: 1px solid #ddd; padding: 8px;\">$info->{owner}</td>\n";      
            print $fh "                    <td style=\"border: 1px solid #ddd; padding: 8px;\">$info->{codeline}</td>\n";      
            print $fh "                    <td style=\"border: 1px solid #ddd; padding: 8px;\">$info->{dirSize} GB</td>\n";      
            print $fh "                    <td style=\"border: 1px solid #ddd; padding: 8px;\">$info->{reason}</td>\n";      
            print $fh "                </tr>\n";      
        }      
      
        print $fh "            </tbody>\n";      
        print $fh "        </table>\n<br class=\"volume-$valid_volume\">\n";      
    }      
} 

sub print_user_bad_workspaces {    
    my ($fh) = @_;    
        
    print $fh "<div class=\"workspace-report\" style=\"margin-left:15px; margin-right:15px\">\n";    
    print $fh "    <h3>Users With 5 Or More Bad Reviewable Workspaces</h3>\n";    
    
    print $fh "    <div class=\"collapsible-header\" style=\"cursor: pointer;\" onclick=\"toggleVisibility('outer-content')\">\n";  
    print $fh "         <span class=\"toggle-icon\">+</span> Toggle All Users Workspaces\n";  
    print $fh "    </div>\n";  
    print $fh "    <div id=\"outer-content\" style=\"display: none;\">\n";
    print $fh "    <div style=\"margin-left:15px; margin-right:15px\">\n";
    
    foreach my $user (sort { $badWorkspaceCountsByUser{$b} <=> $badWorkspaceCountsByUser{$a} } keys %badWorkspaceCountsByUser) 
    {    
        if (IsServiceAccount($user)) { next; }    # Don't report service accounts    
        
        last if $badWorkspaceCountsByUser{$user} < 5;   

        print $fh "    <hr>\n";    
        print $fh "    <a name=\"${user}_bad_workspaces\"></a>\n";  
        print $fh "    <div class=\"collapsible-header\" style=\"cursor: pointer;\" onclick=\"toggleVisibility('content-$user')\">\n";  
        print $fh "        <span class=\"toggle-icon\">+</span> $user Bad Workspaces To Be Reviewed/Removed\n";      
        print $fh "    </div>\n";      
        print $fh "    <div id=\"content-$user\" style=\"display: none;\">\n"; 
  
        print $fh "    <ul>\n";    
        foreach my $workspace (@{$badWorkspacesByUser{$user}}) {    
            print $fh "    <li>$workspace</li>\n";    
        }    
        print $fh "    </ul>\n";   
        print $fh "    </div>\n"; 
    }    
  
    print $fh "         </div>\n";    
    print $fh "    </div>\n";    
    print $fh "</div>\n";   
    print $fh "<hr>\n";   
}    
  
sub print_user_all_workspaces {  
    my ($fh) = @_;  
  
    print $fh "<div class=\"workspace-report\" style=\"margin-left:15px; margin-right:15px\">\n";      
    print $fh "    <h3>Users with 10 or More All Workspaces</h3>\n";      
    print $fh "    <div class=\"collapsible-header\" style=\"cursor: pointer;\" onclick=\"toggleVisibility('all-outer-content')\">\n";  
    print $fh "         <span class=\"toggle-icon\">+</span> Toggle All Users Workspaces\n";  
    print $fh "    </div>\n";  
    print $fh "    <div id=\"all-outer-content\" style=\"display: none;\">\n";  
    print $fh "    <div style=\"margin-left:15px; margin-right:15px\">\n";
    foreach my $user (sort { $allWorkspaceCountsByUser{$b} <=> $allWorkspaceCountsByUser{$a} } keys %allWorkspaceCountsByUser) {      
        if ($allWorkspaceCountsByUser{$user} < 10) { last; }      
        if (IsServiceAccount($user)) { next; }    # Don't report service accounts    
  
        print $fh "    <hr>\n";      
        print $fh "    <a name=\"${user}_all_workspaces\"></a>\n";      
        print $fh "    <div class=\"collapsible-header\" style=\"cursor: pointer;\" onclick=\"toggleVisibility('content-all-$user')\">\n";  
        print $fh "        <span class=\"toggle-icon\">+</span> $user All Workspaces\n";      
        print $fh "    </div>\n";      
        print $fh "    <div id=\"content-all-$user\" style=\"display: none;\">\n";  # Initially hidden      
  
        print $fh "    <ul>\n";      
        foreach my $workspace (@{$allWorkspacesByUser{$user}}) {      
            print $fh "    <li>$workspace</li>\n";      
        }      
        print $fh "    </ul>\n";      
  
        print $fh "    </div>\n";  # Close content div        
    }      
  
    print $fh "         </div>\n";      
    print $fh "    </div>\n";      
    print $fh "</div>\n";      
} 

sub print_footer {  
    my ($fh) = @_;  
      
    print $fh "<hr>\n";
    print $fh "<div style=\"text-align:right\">\n";  
    print $fh "<pre>\n";  
    print $fh "Start Time:  $startTime\n";  
    print $fh "End Time:  $endTime\n";  
    print $fh "</pre>\n";  
    print $fh "</div>\n";
    print $fh "</body>";
    print $fh "</html>";
}  
