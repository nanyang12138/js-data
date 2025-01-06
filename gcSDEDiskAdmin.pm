#!/bin/env perl

################################################################################################
# Copyright (c) 2020 Advanced Micro Devices, Inc.  All rights reserved.
################################################################################################

package gcSDEDiskAdmin;

use strict;
use warnings;
use Data::Dumper;
use DBI;
use Time::Piece;

############################################################################################################
# Global variables

############################################################################################################
# Process all SDE disks
sub ProcessDisks {  
    my ($debug) = @_;

    my $dbh = GetDatabaseHandle()  
        or die "Couldn't make mysql database connection. $DBI::errstr\n";  

    my $list_of_filers = GetGfxipSdeDiskList($dbh);

    if ($debug) { print Dumper($list_of_filers); } 

    my %quota_data;
    my %total_user;

    foreach my $disk (@$list_of_filers) 
    {
        my $script = '/tool/sysadmin/netapp/scripts/get_quota.pl'; 
        my $time = (localtime(time - 2 * 24 * 60 * 60))->strftime('%Y-%m-%d'); # get the date two days ago
        open my $fh, '-|', "$script --disk $disk --date $time" or die "Couldn't run $script: $!\n";  
  
        while (<$fh>) {  
            chomp;  
            next if $_ =~ /SITE\s+FILER/; # skip the header line  
  
            if (/^\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+\s+\S+)$/) {  
                my ($site, $filer, $qtree, $type, $percent_used, $gb_used, $gb_limit, $file_used, $file_limit, $insert) = ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10);  

                # Modify $qtree to replace the beginning with '/proj'  
                if ($qtree =~ m|/([^/]+)$|) {  
                    $qtree = "/proj/$1";  
                } 

                my %quota_info = (  
                    site         => $site,  
                    filer        => $filer,  
                    qtree        => $qtree,  
                    percent_used => $percent_used,  
                    gb_used      => $gb_used,  
                    gb_limit     => $gb_limit,  
                    file_used    => $file_used,  
                    file_limit   => $file_limit,  
                    insert       => $insert,  
                );  
  
                push @{$quota_data{$type}}, \%quota_info; 
                
                $total_user{$type} = 1;
            } else {  
                print "Cannot parse the line: $_\n";  
            }  
        }  
        close $fh; 
    }

    return \%quota_data, \%total_user;
}  


############################################################################################################  
# Check disk usage and send notifications if usage is below a certain threshold  
sub CheckSdeUsageAndNotify {  
    my ($quota_data, $total_user, $debug) = @_;

    foreach my $type (keys %$quota_data) {  
        # Create an array to store entries with low usage  
        my @low_usage_quota_info;  
  
        # Go through each quota entry for the current type  
        foreach my $quota_info (@{$quota_data->{$type}}) {  
            # Update the low usage records in the database
            UpdateLowUsageRecords($type, $quota_info, $total_user);

            # Check if the percent used is less than 5%  
            if ($quota_info->{percent_used} < 5) {  
                # Add this entry to the low usage list  
                push @low_usage_quota_info, $quota_info;  
            }  
        }  
  
        # If there are any entries with low usage, send an email notification  
        if (@low_usage_quota_info) {  
            Notify($type, \@low_usage_quota_info, $debug);  
        }  
    }  
}  

############################################################################################################
# Update low usage records in the database  
sub UpdateLowUsageRecords {  
    my ($user, $quota_info, $total_user) = @_;  
    
    return if $user eq "*" || $user eq "root";

    my $dbh = GetSdeDatabaseHandle()  
        or die "Couldn't make mysql database connection. $DBI::errstr\n";  
  
    my $qtree = $quota_info->{qtree};
    my $percent_used = $quota_info->{percent_used};
    my $last_recorded_date = localtime->strftime('%Y-%m-%d');

    # check if the user is in the list of total users
    unless (exists $total_user->{$user}) {
        my $sth = $dbh->prepare("DELETE FROM sde_low_usage_records WHERE user_id = ?")  
            or die "Couldn't prepare statement: $DBI::errstr\n";
        
        $sth->execute($user) or die "Couldn't execute statement: $DBI::errstr\n";
        $sth->finish();
        $dbh->disconnect();
        return;
    }

    # check if the record already exists in the database
    my $sth = $dbh->prepare("SELECT record_count FROM sde_low_usage_records WHERE user_id = ? AND qtree = ?")  
        or die "Couldn't prepare statement: $DBI::errstr\n";
    
    $sth->execute($user, $qtree) or die "Couldn't execute statement: $DBI::errstr\n";

    my $record_count = $sth->fetchrow_array();
    $sth->finish();

    if ($percent_used < 5) {
        if (defined $record_count) {
            # update the record in the database
            $sth = $dbh->prepare("UPDATE sde_low_usage_records SET last_recorded_date = ?, record_count = record_count + 1, percent_used = ? WHERE user_id = ? AND qtree = ?");  
            $sth->execute($last_recorded_date, $percent_used, $user, $qtree);  
            $sth->finish();
        } else {
            # insert the record into the database
            $sth = $dbh->prepare("INSERT INTO sde_low_usage_records (user_id, qtree, last_recorded_date, percent_used, record_count) VALUES (?, ?, ?, ?, 1)");  
            $sth->execute($user, $qtree, $last_recorded_date, $percent_used);  
            $sth->finish();
        }
    } else {
        # delete the record from the database
        $sth = $dbh->prepare("DELETE FROM sde_low_usage_records WHERE user_id = ? AND qtree = ?");
        $sth->execute($user, $qtree);
        $sth->finish();
    }
    $dbh->disconnect();
}

############################################################################################################
# Get the list of filers that are related to graphics IP
sub GetGfxipSdeDiskList {  
    my ($dbh) = @_;  
  
    my $disklist = $dbh->prepare("SELECT qtree FROM FileSystems WHERE qtree LIKE '%gfxip_sde%' OR qtree LIKE '%mi%-sde%'")  
        or die "Couldn't prepare statement: $DBI::errstr\n";  
  
    $disklist->execute() or die "Couldn't execute statement: $DBI::errstr\n";  
  
    my @disklist;  
    while (my $row = $disklist->fetchrow_array()) {  
        push @disklist, $row;  
    }  
    $disklist->finish();  
    $dbh->disconnect();  
  
    return \@disklist;  
}  
  
############################################################################################################
# Get the database handle
sub GetDatabaseHandle {  
    my $dbi = 'dbi:mysql:database=DataServices;host=atlmysql03.amd.com;user=ds_user;password=ds_passwd';  
  
    my $dbh = DBI->connect("$dbi")  
        or die "Couldn't make mysql database connection. $DBI::errstr\n";  
    return $dbh;  
}  

############################################################################################################
# Get SDE database handle
sub GetSdeDatabaseHandle { 
    my $dbi = 'dbi:Pg:dbname=gfx_disk_monitor;host=atlvshrdpgdbd01;port=5432';  
  
    my $dbh = DBI->connect($dbi, 'gc_infra', 'D2mV(19EH', { AutoCommit => 1, RaiseError => 1 })  
        or die "Couldn't make PostgreSQL database connection. $DBI::errstr\n";    
  
    return $dbh; 
}

############################################################################################################
# Get the list of waived users
sub GetWaivedUsers {  
    my $waiver_file = "//tools/internal/gc_infra/main/src/tools/scripts/admin/disks/data/sde_waivers.txt";

    my @waived_users = split '\n', `p4 -p atlvp4p01.amd.com:1677 print -q $waiver_file`;

    my %waived_users = map { $_ => 1 } @waived_users;

    return \%waived_users;

}

############################################################################################################  
# Notify  
sub Notify {  
    my ($user, $quota_info_list, $debug) = @_; 

    my $waived_users = GetWaivedUsers(); 

    return if (exists $waived_users->{$user});

    return if $user eq "*" || $user eq "root";  
  
    my $dbh = GetSdeDatabaseHandle(); 

    foreach my $quota_info (@$quota_info_list) {  
        my $sth = $dbh->prepare("SELECT record_count FROM sde_low_usage_records WHERE user_id = ? AND qtree = ?");  
        $sth->execute($user, $quota_info->{qtree});  
        my ($record_count) = $sth->fetchrow_array();  
        $sth->finish();  
  
        if (defined $record_count) {  
            if ($record_count <= 3) {  
                SendEmail($user, $quota_info, "warning", $debug);  
            } elsif ($record_count >= 4) {  
                SendEmail($user, $quota_info, "cancellation", $debug); 
            }  
        }  
    }  
  
    $dbh->disconnect();  

}  
  
############################################################################################################  
# Send Email  
sub SendEmail {  
    my ($user, $quota_info, $type, $debug) = @_;  
    
    my $email;
    if ($debug) {
        $email = "$ENV{USER}\@atlmail.amd.com";
    } else {
        $email = "$user\@atlmail.amd.com";
    }

    my $sendmailpath = "/usr/sbin/sendmail";  
  
    open my $sendmail, "|-", "$sendmailpath -t" or do {  
        print "ERROR: Couldn't connect to sendmail!!\n";  
        return 0;  
    };  
  
    my $subject;  
    my $message;  
  
    if ($type eq "warning") {  
        $subject = "Immediate Action Required: Graphics Disk Usage Alert";  
        $message = "<p>Your current disk usage is critically low, falling below the 5% threshold. Please take immediate action to manage your data usage effectively.</p>  
                    <p>Consider transferring data from other disks to the <strong>sde</strong> disk to optimize your storage allocation.</p>  
                    <p>Failure to address this issue may result in the reallocation of your disk space to accommodate other users with higher demands.</p>";  
    } elsif ($type eq "cancellation") {  
        $subject = "Cancellation Notice: Disk Access";  
        $message = "<p>Your SDE disk usage has been below 5% for three consecutive checks. Your access will be revoked.</p>";  
    }  
  
    print $sendmail "Subject: $subject\n";  
    print $sendmail "Content-Type: text/html; charset=\"us-ascii\"\n";  
    print $sendmail "From: Graphics Disk Monitor <dl.gfxip.disk_monitor\@amd.com>\n";  
    print $sendmail "To: $email\n";  
    print $sendmail "<html><body style='font-family: Arial, sans-serif;'>\n";  
    print $sendmail "<h2 style='color: #d9534f;'>$subject</h2>\n";  
    print $sendmail "<p>Dear $user,</p>\n";  
    print $sendmail "$message\n";  
    print $sendmail "<table border='1' cellpadding='5' cellspacing='0' style='border-collapse: collapse; width: 100%;'>\n";  
    print $sendmail "<tr style='background-color: #f2f2f2;'>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>Site</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>Disk</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>User</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>Percent Used</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>GB Used</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>GB Limit</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>File Used</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>File Limit</th>\n";  
    print $sendmail "</tr>\n";  
    print $sendmail "<tr>\n";  
    print $sendmail "<td style='padding: 8px;'>$quota_info->{site}</td>\n";  
    print $sendmail "<td style='padding: 8px;'>$quota_info->{qtree}</td>\n";  
    print $sendmail "<td style='padding: 8px;'>$user</td>\n";  
    print $sendmail "<td style='padding: 8px; color: red;'>$quota_info->{percent_used}%</td>\n";  
    print $sendmail "<td style='padding: 8px;'>$quota_info->{gb_used}</td>\n";  
    print $sendmail "<td style='padding: 8px;'>$quota_info->{gb_limit}</td>\n";  
    print $sendmail "<td style='padding: 8px;'>$quota_info->{file_used}</td>\n";  
    print $sendmail "<td style='padding: 8px;'>$quota_info->{file_limit}</td>\n";  
    print $sendmail "</tr>\n";  
    print $sendmail "</table>\n";  
    print $sendmail "<p>We appreciate your prompt attention to this matter. Please do not hesitate to reach out if you have any questions or require further assistance.</p>\n";  
    print $sendmail "<p>Best regards,<br>Graphics Disk Monitor Team</p>\n";  
    print $sendmail "</body></html>\n";  
  
    close $sendmail;  
  
    return 1;  
}  

############################################################################################################
# Get users exceeding disk usage limit
sub GetUsersExceedingLimit {  
    my $dbh = GetSdeDatabaseHandle();

    # Query to get users with record count greater than 3
    my $sth = $dbh->prepare("SELECT user_id, qtree, last_recorded_date, percent_used, record_count FROM sde_low_usage_records WHERE record_count > 3")  
        or die "Couldn't prepare statement: $DBI::errstr\n";
    
    $sth->execute() or die "Couldn't execute statement: $DBI::errstr\n";

    my @users_exceeding_limit;

    while (my $row = $sth->fetchrow_hashref()) {  
        push @users_exceeding_limit, $row;  
    }

    $sth->finish();
    $dbh->disconnect();

    return \@users_exceeding_limit;
}

############################################################################################################    
# Notify Admin    
sub NotifyAdmin {  
    my ($debug) = @_;

    my $users_exceeding_limit = GetUsersExceedingLimit();

    return unless @$users_exceeding_limit;

    my $admin_email;

    if ($debug) {
        $admin_email = "$ENV{USER}\@atlmail.amd.com";  
    } else {
        $admin_email = "dl.gfxip.disk_monitor\@amd.com";  
    }

    my $sendmailpath = "/usr/sbin/sendmail";    
  
    open my $sendmail, "|-", "$sendmailpath -t" or do {    
        print "ERROR: Couldn't connect to sendmail!!\n";    
        return 0;    
    };    
    
    print $sendmail "Subject: Users Eligible for SDE Disk Cancellation\n";      
    print $sendmail "Content-Type: text/html; charset=\"us-ascii\"\n";      
    print $sendmail "From: Graphics Disk Monitor <dl.gfxip.disk_monitor\@amd.com>\n";      
    print $sendmail "To: $admin_email\n";      
    print $sendmail "<html><body style='font-family: Arial, sans-serif;'>\n";      
    print $sendmail "<h2 style='color: #d9534f;'>Users Eligible for SDE Disk Cancellation</h2>\n";      
    print $sendmail "<p>The following users have been reminded more than three times about their low disk usage and are now eligible for SDE disk cancellation:</p>\n";      
    print $sendmail "<table border='1' cellpadding='5' cellspacing='0' style='border-collapse: collapse; width: 100%;'>\n";      
    print $sendmail "<tr style='background-color: #f2f2f2;'>\n";      
    print $sendmail "<th style='padding: 8px; text-align: left;'>User</th>\n";      
    print $sendmail "<th style='padding: 8px; text-align: left;'>Disk</th>\n";      
    print $sendmail "<th style='padding: 8px; text-align: left;'>Percent Used</th>\n";     
    print $sendmail "<th style='padding: 8px; text-align: left;'>Reminder Count</th>\n";     
    print $sendmail "</tr>\n";      
  
    foreach my $entry (@$users_exceeding_limit) {    
        print $sendmail "<tr>\n";    
        print $sendmail "<td style='padding: 8px;'>$entry->{user_id}</td>\n";    
        print $sendmail "<td style='padding: 8px;'>$entry->{qtree}</td>\n";    
        print $sendmail "<td style='padding: 8px; color: red;'>$entry->{percent_used}%</td>\n";    
        print $sendmail "<td style='padding: 8px;'>$entry->{record_count}</td>\n";    
        print $sendmail "</tr>\n";  
    }    
  
    print $sendmail "</table>\n";      
    print $sendmail "<p>Please review the above users and proceed with the necessary actions for SDE disk cancellation.</p>\n";      
    print $sendmail "<p>Best regards,<br>Graphics Disk Monitor Team</p>\n";      
    print $sendmail "</body></html>\n";      
  
    close $sendmail;    
  
    return 1;    
}  

############################################################################################################
# Send sde user's emails

sub SendSdeEmails {  
    my ($user, $quota_info_list, $group, $volume) = @_;

    my $waived_users = GetWaivedUsers(); 

    return if (exists $waived_users->{$user});

    my $email = "$user\@atlmail.amd.com";
    my $sendmailpath = "/usr/sbin/sendmail";  
  
    open my $sendmail, "|-", "$sendmailpath -t" or do { 
        print "ERROR: Couldn't connect to sendmail!!\n";  
        return 0; 
    };  
  
    print $sendmail "Subject: Graphics Disk Usage Alert\n";  
    print $sendmail "Content-Type: text/html; charset=\"us-ascii\"\n";  
    print $sendmail "From: Graphics Disk Monitor <dl.gfxip.disk_monitor\@amd.com>\n";  
    print $sendmail "To: $email\n";  
    print $sendmail "<html><body style='font-family: Arial, sans-serif;'>\n";  
    print $sendmail "<p>Dear $user,</p>\n";    
    print $sendmail "<p>We hope this message finds you well. As part of our ongoing efforts to optimize disk usage and ensure efficient resource management, we would like to bring to your attention the current status of your disk usage.</p>\n";    
    print $sendmail "<p>Your usage on the disk (/proj/$volume) has exceeded 500GB (http://atlweb01.amd.com/gfxweb/stats/graphicsDiskReview_$group.html#$volume). To maintain optimal performance and resource allocation, we kindly request that you optimize your usage on /proj/$volume disk and consider transferring some of your data to the designated SDE disk.</p>\n";    
    print $sendmail "<table border='1' cellpadding='5' cellspacing='0' style='border-collapse: collapse; width: 100%;'>\n";    
    print $sendmail "<tr style='background-color: #f2f2f2;'>\n";    
    print $sendmail "<th style='padding: 8px; text-align: left;'>Site</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>SDE Disk</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>User</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>Percent Used</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>GB Used</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>GB Limit</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>File Used</th>\n";  
    print $sendmail "<th style='padding: 8px; text-align: left;'>File Limit</th>\n";  
    print $sendmail "</tr>\n";  
  
    foreach my $quota_info (@$quota_info_list) {  
        print $sendmail "<tr>\n";  
        print $sendmail "<td style='padding: 8px;'>$quota_info->{site}</td>\n";  
        print $sendmail "<td style='padding: 8px;'>$quota_info->{qtree}</td>\n";  
        print $sendmail "<td style='padding: 8px;'>$user</td>\n";  
        print $sendmail "<td style='padding: 8px; color: red;'>$quota_info->{percent_used}%</td>\n";  
        print $sendmail "<td style='padding: 8px;'>$quota_info->{gb_used}</td>\n";  
        print $sendmail "<td style='padding: 8px;'>$quota_info->{gb_limit}</td>\n";  
        print $sendmail "<td style='padding: 8px;'>$quota_info->{file_used}</td>\n";  
        print $sendmail "<td style='padding: 8px;'>$quota_info->{file_limit}</td>\n";  
        print $sendmail "</tr>\n";  
    }  
  
    print $sendmail "</table>\n";  
    print $sendmail "<p>If you believe that which workspace on the project disk needs to be retained, please let us know. We can add it to the waiver list for consideration. Please do not hesitate to reach out if you have any questions or require further assistance.</p>\n";  
    print $sendmail "<p>Best regards,<br>Graphics Disk Monitor Team</p>\n";  
    print $sendmail "</body></html>\n";  
  
    close $sendmail;  
  
    return 1; 
} 

# End of module
1;
