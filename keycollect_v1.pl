#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Find;
use Getopt::Long;

my $path;
my $keyword = '';
my $output_params = '1-B,C';
my $key_match = 'exact';
my $current_dir = 0;

GetOptions(
    'path=s'          => \$path,
    'keyword=s'       => \$keyword,
    'output_params=s' => \$output_params,
    'key-match=s'     => \$key_match,
    'current'         => \$current_dir,
) or die usage();

die usage() if $current_dir && defined $path;
die "Invalid --key-match value '$key_match'. Use 'exact' or 'base'.\n"
    unless $key_match eq 'exact' || $key_match eq 'base';

my @requested_keys = parse_output_params($output_params);
my $target_dir = $current_dir ? '.' : (defined $path ? $path : '.');

read_files_in_dir($target_dir);

sub usage {
    return "Usage: $0 [--path=<directory> | --current] [--keyword=<keyword>] [--output_params=<params>] [--key-match=exact|base]\n";
}

sub parse_output_params {
    my ($value) = @_;
    return () unless defined $value && length $value;

    my @params;
    foreach my $item (split /,/, $value) {
        $item =~ s/^\s+//;
        $item =~ s/\s+$//;
        push @params, $item if length $item;
    }

    return @params;
}

sub parse_line_value {
    my ($line) = @_;
    return unless defined $line;

    $line =~ s/\r$//;
    return unless $line =~ /^\s*([\w-]+)\s*[:=]\s*(.+?)\s*$/;

    my ($key, $raw_value) = ($1, $2);
    my $value = first_value($raw_value);
    return unless defined $value;

    return ($key, $value);
}

sub first_value {
    my ($raw_value) = @_;
    return unless defined $raw_value && length $raw_value;

    if ($raw_value =~ /^\s*"([^"]*)"/) {
        return $1;
    }

    if ($raw_value =~ /^\s*'([^']*)'/) {
        return $1;
    }

    if ($raw_value =~ /^\s*([^\s]+)/) {
        return $1;
    }

    return;
}

sub read_file {
    my ($filename) = @_;

    open my $fh, '<', $filename or do {
        warn "Could not open '$filename': $!\n";
        return;
    };

    my @occurrences;
    while (my $line = <$fh>) {
        chomp $line;
        my ($key, $value) = parse_line_value($line);
        next unless defined $key;
        push @occurrences, [$key, $value];
    }

    close $fh;
    return \@occurrences;
}

sub matches_keyword {
    my ($text, $needle) = @_;
    return 1 unless defined $needle && length $needle;
    return $text =~ /\Q$needle\E/i;
}

sub natural_path_cmp {
    my ($left, $right) = @_;

    my @left_parts = ($left =~ /(\d+|\D+)/g);
    my @right_parts = ($right =~ /(\d+|\D+)/g);
    my $shared_length = @left_parts < @right_parts ? scalar @left_parts : scalar @right_parts;

    foreach my $index (0 .. $shared_length - 1) {
        my ($left_part, $right_part) = ($left_parts[$index], $right_parts[$index]);
        my $cmp;

        if ($left_part =~ /^\d+$/ && $right_part =~ /^\d+$/) {
            $cmp = $left_part <=> $right_part;
        } else {
            $cmp = $left_part cmp $right_part;
        }

        return $cmp if $cmp;
    }

    my $remaining_cmp = scalar(@left_parts) <=> scalar(@right_parts);
    return $remaining_cmp if $remaining_cmp;

    return $left cmp $right;
}

sub read_files_in_dir {
    my ($dir) = @_;
    die "Directory '$dir' does not exist.\n" unless -d $dir;

    my @all_files;
    find(
        {
            wanted => sub {
                my $full_path = $File::Find::name;
                return unless -f $full_path;
                return unless $full_path =~ /\.txt$/i;
                return unless matches_keyword($full_path, $keyword);
                push @all_files, $full_path;
            },
            no_chdir => 1,
        },
        $dir,
    );

    @all_files = sort { natural_path_cmp($a, $b) } @all_files;

    my @raw_rows;
    foreach my $file_path (@all_files) {
        my $occurrences_ref = read_file($file_path);
        next unless $occurrences_ref;
        my $absolute_path = abs_path($file_path) // $file_path;
        push @raw_rows, {
            File_Name   => $absolute_path,
            Occurrences => $occurrences_ref,
        };
    }

    my $group_info_ref = build_group_info(\@raw_rows);
    my ($data_ref, $max_counts_ref) = build_output_rows(\@raw_rows, $group_info_ref);
    my @normalized_requested_keys = normalize_requested_keys(\@requested_keys, $group_info_ref);

    write_to_csv_basic($data_ref, $max_counts_ref, \@normalized_requested_keys);
}

sub build_group_info {
    my ($raw_rows_ref) = @_;
    my %group_info;

    foreach my $row_ref (@{$raw_rows_ref}) {
        foreach my $entry_ref (@{$row_ref->{Occurrences}}) {
            my ($key) = @{$entry_ref};
            if ($key =~ /^(.*?)(\d+)$/ && length $1) {
                $group_info{$1}{suffix_keys}{$key} = 1;
            } else {
                $group_info{$key}{plain_key} = 1;
            }
        }
    }

    return \%group_info;
}

sub normalize_key_for_output {
    my ($key, $group_info_ref) = @_;
    return $key if $key_match eq 'exact';

    if ($key =~ /^(.*?)(\d+)$/ && length $1) {
        my $base = $1;
        my $suffix_keys_ref = $group_info_ref->{$base}{suffix_keys} || {};
        my $suffix_count = scalar keys %{$suffix_keys_ref};
        my $has_plain = $group_info_ref->{$base}{plain_key} || 0;
        return $base if $suffix_count > 1 || $has_plain;
    }

    return $key;
}

sub normalize_requested_keys {
    my ($requested_ref, $group_info_ref) = @_;
    return () unless @{$requested_ref};

    my @normalized;
    foreach my $key (@{$requested_ref}) {
        push @normalized, normalize_key_for_output($key, $group_info_ref);
    }

    my %seen;
    return grep { !$seen{$_}++ } @normalized;
}

sub build_output_rows {
    my ($raw_rows_ref, $group_info_ref) = @_;
    my @data;
    my %max_counts;

    foreach my $raw_row_ref (@{$raw_rows_ref}) {
        my %row = (File_Name => $raw_row_ref->{File_Name});

        foreach my $entry_ref (@{$raw_row_ref->{Occurrences}}) {
            my ($original_key, $value) = @{$entry_ref};
            my $output_key = normalize_key_for_output($original_key, $group_info_ref);
            push @{$row{$output_key}}, $value;
        }

        foreach my $key (keys %row) {
            next if $key eq 'File_Name';
            my $count = scalar @{$row{$key}};
            $max_counts{$key} = $count if $count > ($max_counts{$key} // 0);
        }

        push @data, \%row;
    }

    return (\@data, \%max_counts);
}

sub selected_keys {
    my ($max_counts_ref, $requested_ref) = @_;

    if (@{$requested_ref}) {
        return grep { exists $max_counts_ref->{$_} } @{$requested_ref};
    }

    return sort keys %{$max_counts_ref};
}

sub build_header {
    my ($max_counts_ref, $requested_ref) = @_;
    my @header = ('File_Name');

    foreach my $key (selected_keys($max_counts_ref, $requested_ref)) {
        my $count = $max_counts_ref->{$key} // 0;
        next unless $count;

        if ($count == 1) {
            push @header, $key;
        } else {
            push @header, map { "${key}_$_" } 1 .. $count;
        }
    }

    return @header;
}

sub escape_csv_value {
    my ($value) = @_;
    $value = '' unless defined $value;

    $value =~ s/"/""/g;
    if ($value =~ /[",\r\n]/ || $value =~ /^\s/ || $value =~ /\s$/) {
        $value = qq("$value");
    }

    return $value;
}

sub row_values_for_key {
    my ($row_ref, $key, $count) = @_;
    my @values = exists $row_ref->{$key} ? @{$row_ref->{$key}} : ();

    if ($count == 1) {
        return ($values[0] // '');
    }

    my @expanded;
    foreach my $index (0 .. $count - 1) {
        push @expanded, $values[$index] // '';
    }

    return @expanded;
}

sub write_to_csv_basic {
    my ($data_ref, $max_counts_ref, $requested_ref) = @_;

    open my $csv, '>', 'merged_data.csv' or die "Could not open merged_data.csv: $!\n";

    my @header = build_header($max_counts_ref, $requested_ref);
    print {$csv} join(',', @header), "\n";

    my @keys = selected_keys($max_counts_ref, $requested_ref);
    foreach my $row_ref (@{$data_ref}) {
        my @row = (escape_csv_value($row_ref->{File_Name}));

        foreach my $key (@keys) {
            my $count = $max_counts_ref->{$key} // 0;
            push @row, map { escape_csv_value($_) } row_values_for_key($row_ref, $key, $count);
        }

        print {$csv} join(',', @row), "\n";
    }

    close $csv;
    print "Merged CSV file created successfully as 'merged_data.csv'.\n";
}
