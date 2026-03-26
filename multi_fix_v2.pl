use strict;
use warnings;
use File::Copy qw(copy);
use File::Path qw(make_path remove_tree);
use File::Spec;

# =========================
# 使用者設定區
# =========================
my $OUTPUT_DIR    = 'output';
my $MAX_PROCESSES = 10;

# 每個 case 都要一併放入 output 子資料夾的靜態檔案。
# 如果 command 會用到額外輸入檔，例如 modelcard，請放在這裡。
my @files_to_copy = (
    '1.txt',
);

# 維持原本的 flat 寫法：
# file     : 要修改的檔案
# keyword  : 要搜尋並替換的字串
# new_lines: 這個欄位的所有候選值，程式會自動做組合
#
# lines 可用三種方式：
# 1. [11, 15]  : 指定行號
# 2. 'all'     : 替換所有符合 keyword 的行
# 3. 省略      : keyword 只出現一次時自動採用；若出現多次則報錯
#
# 如果檔案就在目前路徑下，直接寫 netlist.sh 即可。
# 只有當你有不同子資料夾下的同名檔案時，才需要寫相對路徑，
# 例如 case_a/netlist.sh、case_b/netlist.sh。
my @modifications = (
    { file => 'netlist.sh', keyword => 'lkvth0 = 0', new_lines => ['lkvth0 = 2', 'lkvth0 = 0'] },
    { file => 'netlist.sh', keyword => 'dvt0 = 0',   new_lines => ['dvt0 = 0',   'dvt0 = 6'] },
    # { file => 'netlist.sh', keyword => 'foo = 1', lines => 'all', new_lines => ['foo = 2', 'foo = 3'] },
    # { file => 'netlist.sh', keyword => 'bar = 9', new_lines => ['bar = 7', 'bar = 9'] },
);

# 依序在每個 output 子資料夾中執行。
my @commands = (
    "sh netlist.sh > 2.txt",
    "grep 'vth' 2.txt > 3.txt",
);

sub read_file {
    my ($file_path) = @_;
    open my $file, '<', $file_path or die "Cannot open file: $file_path\n";
    local $/;
    my $content = <$file>;
    close $file;
    return $content;
}

sub save_file {
    my ($file_path, $content) = @_;
    my (undef, $dirs, undef) = File::Spec->splitpath($file_path);
    make_path($dirs) if length $dirs && !-d $dirs;

    open my $file, '>', $file_path or die "Cannot write to file: $file_path\n";
    print $file $content;
    close $file;
}

sub sanitize_name {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/^\s+|\s+$//g;
    $text =~ s/[\r\n\t]+/ /g;
    $text =~ s/\s{2,}/ /g;
    $text =~ s{[\\/:*?"<>|]+}{_}g;
    $text =~ s/_+/_/g;
    return length $text ? $text : 'value';
}

sub ensure_relative_path {
    my ($path, $field_name) = @_;

    die "$field_name '$path' must be a relative path.\n"
        if File::Spec->file_name_is_absolute($path);
}

sub normalize_modifications {
    my ($config) = @_;
    my @normalized;

    foreach my $mod (@$config) {
        die "Each item in \@modifications must be a hash.\n"
            unless ref $mod eq 'HASH';

        die "A modification is missing file.\n"
            unless defined $mod->{file} && length $mod->{file};
        ensure_relative_path($mod->{file}, 'Modification file');

        die "A modification for file '$mod->{file}' is missing keyword.\n"
            unless defined $mod->{keyword} && length $mod->{keyword};

        die "A modification for file '$mod->{file}' and keyword '$mod->{keyword}' is missing new_lines.\n"
            unless ref $mod->{new_lines} eq 'ARRAY' && @{$mod->{new_lines}};

        if (defined $mod->{lines}) {
            if (!ref $mod->{lines}) {
                die "lines for '$mod->{keyword}' only supports the scalar value 'all'.\n"
                    unless $mod->{lines} eq 'all';
            } else {
                die "lines for '$mod->{keyword}' must be an array reference.\n"
                    unless ref $mod->{lines} eq 'ARRAY';
                die "lines for '$mod->{keyword}' cannot be empty.\n"
                    unless @{$mod->{lines}};
            }
        }

        push @normalized, {
            file      => $mod->{file},
            keyword   => $mod->{keyword},
            lines     => $mod->{lines},
            new_lines => [@{$mod->{new_lines}}],
        };
    }

    return @normalized;
}

sub validate_commands {
    my ($commands) = @_;

    foreach my $cmd (@$commands) {
        die "Each item in \@commands must be a string.\n"
            if ref $cmd;

        die "Found an empty command in \@commands.\n"
            unless defined $cmd && $cmd =~ /\S/;
    }
}

sub extract_first_command_word {
    my ($cmd) = @_;
    my $rest = $cmd;
    $rest =~ s/^\s+//;

    while ($rest =~ s/^\w+=(?:"[^"]*"|'[^']*'|\S+)\s+//) {
    }

    my ($word) = $rest =~ /^([^\s|&;<>()]+)/;
    return $word;
}

sub validate_command_tools {
    my ($commands) = @_;

    foreach my $cmd (@$commands) {
        my $word = extract_first_command_word($cmd);
        next unless defined $word && length $word;
        next if $word =~ m{[/\\]};

        my $status = system('sh', '-lc', "command -v '$word' >/dev/null 2>&1");
        die "Command '$cmd' failed preflight because '$word' was not found in PATH.\n"
            if $status != 0;
    }
}

sub load_original_contents {
    my ($modifications) = @_;
    my %original_contents;

    foreach my $mod (@$modifications) {
        next if exists $original_contents{$mod->{file}};
        $original_contents{$mod->{file}} = read_file($mod->{file});
    }

    return %original_contents;
}

sub find_matching_lines {
    my ($content, $keyword) = @_;
    my @lines = split /\n/, $content, -1;
    my @matches;

    for (my $i = 0; $i < scalar @lines; $i++) {
        push @matches, $i + 1 if $lines[$i] =~ /\Q$keyword\E/;
    }

    return @matches;
}

sub resolve_line_numbers {
    my ($content, $mod) = @_;
    my @lines   = split /\n/, $content, -1;
    my @matches = find_matching_lines($content, $mod->{keyword});

    die "Keyword '$mod->{keyword}' was not found in file '$mod->{file}'.\n"
        unless @matches;

    my $configured_lines = $mod->{lines};

    if (!defined $configured_lines) {
        return \@matches if @matches == 1;
        die "Keyword '$mod->{keyword}' appears multiple times in file '$mod->{file}'. Please set lines => [...], or lines => 'all'.\n";
    }

    if (!ref $configured_lines) {
        return \@matches;
    }

    foreach my $line_num (@$configured_lines) {
        die "Invalid line number '$line_num' for '$mod->{keyword}'.\n"
            unless defined $line_num && $line_num =~ /^\d+$/;

        die "Line number '$line_num' for '$mod->{keyword}' is outside file '$mod->{file}'.\n"
            if $line_num < 1 || $line_num > @lines;

        die "Line $line_num in file '$mod->{file}' does not contain '$mod->{keyword}'.\n"
            unless $lines[$line_num - 1] =~ /\Q$mod->{keyword}\E/;
    }

    return [@$configured_lines];
}

sub prepare_modifications {
    my ($modifications, $original_contents) = @_;

    foreach my $mod (@$modifications) {
        my $content = $original_contents->{$mod->{file}};
        $mod->{resolved_lines} = resolve_line_numbers($content, $mod);
    }
}

sub validate_modification_targets {
    my ($modifications) = @_;
    my %seen_targets;
    my %seen_lines;

    foreach my $mod (@$modifications) {
        foreach my $line_num (@{$mod->{resolved_lines}}) {
            my $key = join "\0", $mod->{file}, $line_num, $mod->{keyword};
            my $line_key = join "\0", $mod->{file}, $line_num;

            die "Duplicate modification target detected for file '$mod->{file}', line $line_num, keyword '$mod->{keyword}'.\n"
                if $seen_targets{$key};

            if (exists $seen_lines{$line_key}) {
                my $previous_keyword = $seen_lines{$line_key};
                die "Multiple modifications target file '$mod->{file}', line $line_num. "
                    . "This is order-dependent ('$previous_keyword' and '$mod->{keyword}'), so please merge them into one edit or use different lines.\n";
            }

            $seen_targets{$key} = 1;
            $seen_lines{$line_key} = $mod->{keyword};
        }
    }
}

sub generate_combinations {
    my @arrays = @_;
    my @combinations = ([]);

    for my $array (@arrays) {
        @combinations = map {
            my $item = $_;
            map { [@$item, $_] } @$array
        } @combinations;
    }

    return @combinations;
}

sub build_cases {
    my ($modifications) = @_;
    return ({ folder_name => 'baseline', modifications => [] }) unless @$modifications;

    my @new_lines_lists = map { $_->{new_lines} } @$modifications;
    my @combinations = generate_combinations(@new_lines_lists);
    my @cases;
    my %seen_folder_names;

    foreach my $combination (@combinations) {
        my @case_modifications;
        my @folder_parts = map { sanitize_name($_) } @$combination;
        my $folder_name = join('_', @folder_parts);

        die "Duplicate folder name generated: '$folder_name'. Please adjust new_lines.\n"
            if $seen_folder_names{$folder_name}++;

        for my $i (0 .. $#$modifications) {
            push @case_modifications, {
                %{$modifications->[$i]},
                replacement_line => $combination->[$i],
            };
        }

        push @cases, {
            folder_name   => $folder_name,
            modifications => \@case_modifications,
        };
    }

    return @cases;
}

sub apply_modifications_to_content {
    my ($content, $modifications) = @_;
    my @lines = split /\n/, $content, -1;

    foreach my $mod (@$modifications) {
        foreach my $line_num (@{$mod->{resolved_lines}}) {
            my $index = $line_num - 1;
            die "Line $line_num in file '$mod->{file}' no longer contains '$mod->{keyword}'.\n"
                unless $lines[$index] =~ /\Q$mod->{keyword}\E/;

            $lines[$index] =~ s/\Q$mod->{keyword}\E/$mod->{replacement_line}/;
        }
    }

    return join "\n", @lines;
}

sub target_path_in_case {
    my ($case_dir, $source_path) = @_;
    my $canon_path = File::Spec->canonpath($source_path);
    my (undef, $dirs, $file) = File::Spec->splitpath($canon_path);
    my @dirs = grep { length $_ && $_ ne '.' } File::Spec->splitdir($dirs);

    return File::Spec->catfile($case_dir, @dirs, $file);
}

sub validate_copy_files {
    my ($files_to_copy) = @_;

    foreach my $file (@$files_to_copy) {
        ensure_relative_path($file, 'Static file');
        die "Static file '$file' does not exist.\n" unless -e $file;
        die "Static path '$file' is not a file.\n" unless -f $file;
    }
}

sub recreate_output_directory {
    my ($output_dir) = @_;

    if (-e $output_dir && !-d $output_dir) {
        die "'$output_dir' exists, but it is not a directory.\n";
    }

    if (-d $output_dir) {
        my $errors;
        remove_tree($output_dir, { error => \$errors });

        if ($errors && @$errors) {
            my @messages;
            foreach my $error (@$errors) {
                my ($path, $message) = %$error;
                push @messages, defined $message ? "$path: $message" : $path;
            }
            die "Failed to remove existing output directory '$output_dir':\n"
                . join("\n", @messages) . "\n";
        }
    }

    make_path($output_dir);
}

sub stage_case_folder {
    my ($output_dir, $case, $original_contents, $files_to_copy) = @_;
    my $case_dir = File::Spec->catdir($output_dir, $case->{folder_name});
    make_path($case_dir);

    foreach my $file (@$files_to_copy) {
        my $target_path = target_path_in_case($case_dir, $file);
        my (undef, $dirs, undef) = File::Spec->splitpath($target_path);
        make_path($dirs) if length $dirs && !-d $dirs;
        copy($file, $target_path) or die "Cannot copy '$file' to '$target_path': $!\n";
    }

    my %mods_by_file;
    foreach my $mod (@{$case->{modifications}}) {
        push @{$mods_by_file{$mod->{file}}}, $mod;
    }

    foreach my $file (sort keys %$original_contents) {
        my $target_path = target_path_in_case($case_dir, $file);
        my $content = $original_contents->{$file};

        if (exists $mods_by_file{$file}) {
            $content = apply_modifications_to_content($content, $mods_by_file{$file});
        }

        save_file($target_path, $content);
    }
}

sub list_case_directories {
    my ($output_dir) = @_;
    opendir my $dh, $output_dir or die "Cannot open output directory '$output_dir'.\n";

    my @dirs = sort map { File::Spec->catdir($output_dir, $_) }
        grep {
            $_ ne '.'
                && $_ ne '..'
                && -d File::Spec->catdir($output_dir, $_)
        } readdir $dh;

    closedir $dh;
    return @dirs;
}

sub run_commands_in_case {
    my ($dir, $commands) = @_;
    chdir $dir or die "Cannot enter directory: $dir";

    foreach my $cmd (@$commands) {
        my $exit_status = system($cmd);

        if ($exit_status == -1) {
            warn "In folder '$dir' failed to start command: $cmd ($!)\n";
            return 1;
        }

        if ($exit_status & 127) {
            my $signal = $exit_status & 127;
            warn "In folder '$dir' command died with signal $signal: $cmd\n";
            return 1;
        }

        my $code = $exit_status >> 8;
        if ($code != 0) {
            warn "In folder '$dir' command exited with code $code: $cmd\n";
            return 1;
        }

        print "Successful in folder '$dir' execute command: $cmd\n";
    }

    return 0;
}

sub record_child_exit {
    my ($pid, $status, $pid_to_dir, $failed_dirs) = @_;
    my $dir = delete $pid_to_dir->{$pid} // "pid:$pid";

    if ($status == -1) {
        push @$failed_dirs, "$dir (wait failed)";
        return;
    }

    if ($status & 127) {
        push @$failed_dirs, "$dir (signal " . ($status & 127) . ")";
        return;
    }

    my $code = $status >> 8;
    push @$failed_dirs, "$dir (exit $code)" if $code != 0;
}

sub wait_for_child {
    my ($pid_to_dir, $failed_dirs) = @_;
    my $pid = wait();

    die "wait() returned no child process unexpectedly.\n"
        if $pid == -1;

    record_child_exit($pid, $?, $pid_to_dir, $failed_dirs);
}

sub process_output_directories {
    my ($output_dir, $commands, $max_processes) = @_;

    die "MAX_PROCESSES must be at least 1.\n"
        unless defined $max_processes && $max_processes =~ /^\d+$/ && $max_processes >= 1;

    unless (-d $output_dir) {
        die "Folder '$output_dir' invalid, Please check path.\n";
    }

    unless (@$commands) {
        print "No commands configured. Folder generation only.\n";
        return;
    }

    my @sub_dirs = list_case_directories($output_dir);
    unless (@sub_dirs) {
        print "No case folders were generated under '$output_dir'.\n";
        return;
    }

    my $current_processes = 0;
    my %pid_to_dir;
    my @failed_dirs;

    foreach my $dir (@sub_dirs) {
        while ($current_processes >= $max_processes) {
            wait_for_child(\%pid_to_dir, \@failed_dirs);
            $current_processes--;
        }

        my $pid = fork();
        if (!defined $pid) {
            die "Cannot generate subprogress: $!";
        } elsif ($pid == 0) {
            my $failed = run_commands_in_case($dir, $commands);
            exit($failed ? 1 : 0);
        } else {
            $pid_to_dir{$pid} = $dir;
            $current_processes++;
        }
    }

    while ($current_processes > 0) {
        wait_for_child(\%pid_to_dir, \@failed_dirs);
        $current_processes--;
    }

    if (@failed_dirs) {
        die "Some case folders failed:\n"
            . join("\n", map { " - $_" } @failed_dirs)
            . "\n";
    }

    print "All check and execution done.\n";
}

sub main {
    my @normalized_modifications = normalize_modifications(\@modifications);
    my %original_contents = load_original_contents(\@normalized_modifications);

    validate_commands(\@commands);
    validate_command_tools(\@commands);
    validate_copy_files(\@files_to_copy);
    prepare_modifications(\@normalized_modifications, \%original_contents);
    validate_modification_targets(\@normalized_modifications);
    recreate_output_directory($OUTPUT_DIR);

    my @cases = build_cases(\@normalized_modifications);
    foreach my $case (@cases) {
        stage_case_folder($OUTPUT_DIR, $case, \%original_contents, \@files_to_copy);
    }

    process_output_directories($OUTPUT_DIR, \@commands, $MAX_PROCESSES);
}

main();
