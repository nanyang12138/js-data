#!/bin/env perl

################################################################################################
# Copyright (c) 2020 Advanced Micro Devices, Inc.  All rights reserved.
################################################################################################

package gcDiskAdmin;

use strict;                 # Always run in strict mode to avoid common pitfalls.
use warnings;
use Scalar::Util;
use File::Basename;

#############################################################################################################
# GetDiskInfo

sub GetDiskInfo
{
    my ($ownershipFile) = @_;

    my $ownershipData;

    if (defined $ownershipFile)
    {
        $ownershipData = GetOwnershipData($ownershipFile);
    }

    my %diskData;

    my %fields;
    $diskData{fields} = \%fields;

    my @data;
    $diskData{data} = \@data;

    my $fsSearch = `/tool/sysadmin/netapp/scripts/fsmanager/fs_search.pl --project gfxip --permissions --format_table -s ATL`;

    my @fsSearchLines = split '\n', $fsSearch;

    my $lineCount = 0;

    foreach my $line (@fsSearchLines)
    {
        chomp $line;

        $lineCount += 1;

        $line =~ s/\s*\|\s*/,/g;    # Convert everything else into csv
        while ($line =~ s/,,/,0,/) {};
        $line =~ s/^,//g;           # Strip leading ,
        $line =~ s/,$//g;           # Strip trailing ,

        if ($lineCount == 1)
        {
            my @fieldArray = split ',', $line;

            push @fieldArray, "Mount";

            my $index = 0;

            foreach my $field (@fieldArray)
            {
                $fields{$field} = $index;
                $index += 1;
            }

            if ((exists $fields{"Size(GB)"}) && (exists $fields{"Used(GB)"}))
            {
                $fields{"Free(GB)"} = $index;         $index += 1;
                $fields{"% Free"} = $index;           $index += 1;
            }

            if (defined $ownershipData)
            {
                $fields{Category} = $index;           $index += 1;
                $fields{Manage} = $index;             $index += 1;
                $fields{Description} = $index;        $index += 1;
                $fields{Owner} = $index;              $index += 1;
            }
        }
        else
        {
            unless (($line =~ m/-----/) || ($line =~ m/Totals:/))
            {
                my @localData = split ',', $line;

                # If it's scheduled for reclaim skip it

                next unless ($localData[$fields{'Reclaim Date'}] eq "0");

                # Add mount info if we can figure that out

                my $mount;

                if ($localData[$fields{Qtree}] =~ m/.*\/(.*)/)
                {
                    $mount = "/proj/$1";

                    if ($mount eq "/proj/gfx8_dv4_new") { $mount = "/proj/gfx8_dv4"; }       # Special case.
                    if ($mount eq "/proj/gfxip-dpl0_nobackup_archive") { $mount = "/proj/gfxip-dpl0_nobackup"; }       # Special case.

                    push @localData, $mount;
                }
                else
                {
                    push @localData, "unknown";
                }

                # Push the free

                if ((exists $fields{"Size(GB)"}) && (exists $fields{"Used(GB)"}))
                {
                    my $freeGB = $localData[$fields{"Size(GB)"}] - $localData[$fields{"Used(GB)"}];

                    my $freePercent;

                    if ($localData[$fields{"Size(GB)"}] > 0) { $freePercent = ($freeGB / $localData[$fields{"Size(GB)"}]) * 100; }
                    else { $freePercent = 0; }

                    push @localData, $freeGB;
                    push @localData, int($freePercent + 0.5);
                }

                # Add ownership information

                if (defined $ownershipData)
                {
                    if ((defined $mount) && (exists $$ownershipData{$mount}))
                    {
                        push @localData, $$ownershipData{$mount}{Category};
                        push @localData, $$ownershipData{$mount}{Manage};
                        push @localData, $$ownershipData{$mount}{Description};
                        push @localData, $$ownershipData{$mount}{Owner};

                        $$ownershipData{$mount}{Found} = 1;
                    }
                    else
                    {
                        push @localData, "unknown";
                        push @localData, "No";
                        push @localData, "none";
                        push @localData, "??";
                    }
                }

                push @data, \@localData;
            }
        }
    }

    foreach my $owner (sort keys %{$ownershipData})
    {
        unless ($$ownershipData{$owner}{Found})
        {
           print "WARNING:  No disk found for $owner!!\n";
        }
    }

    return \%diskData;
}


#############################################################################################################
# GetOwnershipData

sub GetOwnershipData
{
    my ($ownershipFile) = @_;

    my @dataLines = split '\n', `p4 -p atlvp4p01.amd.com:1677 print -q $ownershipFile`;

    my %ownershipData;

    foreach my $line (@dataLines)
    {
        chomp $line;

        $line =~ s/#.*//;
        $line =~ s/^\s+\|\s+$//g;

        if ($line eq "") { next; }

        if ($line =~ m/(\S+)\s+(\S+)\s+(.*)\s+(\S+)/)
        {
            my %lineData;

            $ownershipData{$1} = \%lineData;

            $ownershipData{$1}{Category} = $2;
            $ownershipData{$1}{Description} = $3;
            $ownershipData{$1}{Owner} = $4;
            $ownershipData{$1}{Found} = 0;

            $ownershipData{$1}{Description} =~ s/^\s+\|\s+$//g;
        }
    }

    return \%ownershipData;
}

#############################################################################################################
# GetDiskSfduData

sub GetDiskSfduData
{
    my ($diskpaths) = @_; 

    my @diskSfduFiles = split '\n', `p4 -p atlvp4p01.amd.com:1677 files $diskpaths`;

    my %diskSfduData;

    foreach my $diskSfduFile (@diskSfduFiles) 
    {
        my $filePath = (split('#', $diskSfduFile))[0];

        my @diskLines = split '\n', `p4 -p atlvp4p01.amd.com:1677 print -q $filePath`;

        my ($prefix) = split '_', basename($filePath);

        foreach my $lines (@diskLines) 
        {
            chomp $lines;

            my $line = (split('/', $lines))[-1];
            $line =~ s/^\s+|\s+$//g;

            $diskSfduData{$line} = $prefix;
        }
    }
    return \%diskSfduData;
}

#############################################################################################################
# StringToArray

sub StringToArray
{
    my ($string) = @_;

    my @array;
    push @array, $string;

    return \@array;
}


#############################################################################################################
# PrintFields

sub PrintFields
{
    my ($fields) = @_;

    print "Fields Available:\n";

    foreach my $field (sort keys %{$fields})
    {
        print "    $field\n";
    }
}


#############################################################################################################
# Filter

sub Filter
{
    my ($arrayRef, $fields, $field, $valueRef) = @_;

    my @returnData;

    if (exists $$fields{$field})
    {
        foreach my $element (@{$arrayRef})
        {
            foreach my $value (@{$valueRef})
            {
                if ($$element[$$fields{$field}] eq $value)
                {
                    push @returnData, $element;
                    last;
                }
            }
        }
    }

    return \@returnData;
}


#############################################################################################################
# Exists

sub Exists
{
    my ($arrayRef, $fields) = @_;

    my @existingData;

    foreach my $element (@{$arrayRef})
    {
        if ($$element[$$fields{Qtree}] =~ m/.*\/(.*)/)
        {
            my $dir = "/proj/$1";

            if (-d $dir)
            {
                push @existingData, $element;
            }
        }
    }

    return \@existingData;
}


#############################################################################################################
# Sort

sub Sort
{
    my ($arrayRef, $fields, $field, $hiToLow) = @_;

    my @sortedData;

    if (defined $hiToLow) { @sortedData = sort { $$b[$$fields{$field}] <=> $$a[$$fields{$field}] } @{$arrayRef}; }
    else { @sortedData = sort { $$a[$$fields{$field}] <=> $$b[$$fields{$field}] } @{$arrayRef}; }

    return \@sortedData;
}


#############################################################################################################
# PrintData

sub PrintData
{
    my ($arrayRef, $fields, $fieldList, $fieldWidths) = @_;

    unless (defined $fieldList)
    {
        my @fieldArray;

        foreach my $key (keys %{$fields})
        {
            @fieldArray[$$fields{$key}] = $key;
        }

        $fieldList = \@fieldArray;
    }

    my $i = 0;

    foreach my $header (@{$fieldList})
    {
        if (defined $fieldWidths)
        {
            printf "%-$$fieldWidths[$i]s", $header;
            $i += 1;
        }
        else
        {
            print "$header ";
        }
    }

    print "\n";

    foreach my $element (@{$arrayRef})
    {
        my $bFirst = 1;

        $i = 0;

        foreach my $field (@{$fieldList})
        {
            if (defined $fieldWidths)
            {
                printf "%-$$fieldWidths[$i]s", $$element[$$fields{$field}];
                $i += 1;
            }
            else
            {
                print "$$element[$$fields{$field}]     "
            }
        }
        print "\n";
    }
}


#############################################################################################################
# GetIndex

sub GetIndex
{
    my ($field, $fields) = @_;

    if (exists $$fields{$field}) { return $$fields{$field}; }
    else { return -1; }
}


# End of module
1;

