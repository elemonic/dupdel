use strict;
use warnings;
use utf8;

use FindBin;
use lib $FindBin::Bin;

use Digest::SHA;
use Encode qw(decode);
use File::Spec;
use WinConsoleJP qw(:default :rough);

our $IS_WINDOWS;
our $USE_LONGPATH;

console_init();
init_platform();
main();

sub init_platform {
    $IS_WINDOWS   = ($^O eq 'MSWin32') ? 1 : 0;
    $USE_LONGPATH = 0;

    return unless $IS_WINDOWS;

    eval {
        require Win32::LongPath;
        Win32::LongPath->import(qw(:funcs));
        1;
    } or die "Win32::LongPath の初期化に失敗しました: $@";

    $USE_LONGPATH = 1;
}

sub main {
    my $opt = parse_args(@ARGV);
    my @target_dirs = collect_target_dirs($opt->{target_dir}, $opt);
    my $log_file = make_log_filename();

    print_cp932("モード         : " . ($opt->{do_delete} ? "実削除" : "dry-run") . "\n");
    print_cp932("基準フォルダ   : $opt->{target_dir}\n");
    print_cp932("処理単位       : " . target_mode_label($opt) . "\n");
    print_cp932("処理対象数     : " . scalar(@target_dirs) . "\n");
    print_cp932("keep選択       : " . keep_rule_label($opt) . "\n");
    print_cp932("OS判定         : " . ($IS_WINDOWS ? "Windows" : "非Windows") . "\n");
    if ($IS_WINDOWS) {
        print_cp932("列挙方式       : " . ($USE_LONGPATH ? "Win32::LongPath" : "標準") . "\n");
    }
    if ($opt->{do_delete}) {
        print_cp932("ログファイル   : $log_file\n");
    }
    print_cp932("\n");

    my $log_fh;
    if ($opt->{do_delete}) {
        $log_fh = open_log_file($log_file);
        log_utf8($log_fh, "===== " . timestamp_for_log() . " START =====\n");
        log_utf8($log_fh, "BASE_DIR: $opt->{target_dir}\n");
        log_utf8($log_fh, "MODE: " . target_mode_label($opt) . "\n");
        log_utf8($log_fh, "TARGET_COUNT: " . scalar(@target_dirs) . "\n");
        log_utf8($log_fh, "KEEP_RULE: " . keep_rule_label($opt) . "\n\n");
    }

    my $result = process_target_dirs(\@target_dirs, $opt, $log_fh);

    if ($opt->{do_delete}) {
        log_delete_failures_summary($log_fh, $result->{delete_failures});
        log_utf8($log_fh, "合計件数: フォルダ=$result->{processed_dirs} / 対象=$result->{total_files} / 重複組=$result->{duplicate_groups} / 削除候補=$result->{delete_candidates} / 削除成功=$result->{deleted_count} / 削除失敗=$result->{delete_error_count} / HASH失敗=$result->{hash_error_count}\n");
        log_utf8($log_fh, "===== " . timestamp_for_log() . " END =====\n");
        close $log_fh;
    }

    print_cp932("\n");
    print_cp932("===== 実行結果 =====\n");
    print_cp932("処理フォルダ数     : $result->{processed_dirs}\n");
    print_cp932("対象ファイル数     : $result->{total_files}\n");
    print_cp932("重複グループ数     : $result->{duplicate_groups}\n");
    print_cp932("削除候補数         : $result->{delete_candidates}\n");
    print_cp932("削除実行数         : $result->{deleted_count}\n");
    print_cp932("削除失敗数         : $result->{delete_error_count}\n");
    print_cp932("ハッシュ失敗数     : $result->{hash_error_count}\n");

    if (!$opt->{do_delete}) {
        print_cp932("\n");
        print_cp932("※ dry-run です。実際には削除していません。\n");
        print_cp932("  実際に削除するには --delete を付けて実行してください。\n");
    }
}

sub parse_args {
    my @args = @_;

    my %opt = (
        do_delete    => 0,
        include_self => 0,
        reverse_keep => 0,
    );

    while (@args) {
        my $arg = shift @args;

        if ($arg eq '--delete') {
            $opt{do_delete} = 1;
        }
        elsif ($arg eq '-s') {
            $opt{include_self} = 1;
        }
        elsif ($arg eq '-r') {
            $opt{reverse_keep} = 1;
        }
        elsif ($arg eq '-p') {
            die usage() unless @args;
            $opt{priority_delete} = shift @args;
        }
        elsif ($arg eq '-d') {
            die usage() unless @args;
            die "エラー: -d と -D は同時に指定できません\n" if defined $opt{max_depth};
            $opt{exact_depth} = parse_depth_arg(shift @args, '-d');
        }
        elsif ($arg eq '-D') {
            die usage() unless @args;
            die "エラー: -d と -D は同時に指定できません\n" if defined $opt{exact_depth};
            $opt{max_depth} = parse_depth_arg(shift @args, '-D');
        }
        elsif (!defined $opt{target_dir}) {
            $opt{target_dir} = $arg;
        }
        else {
            die usage();
        }
    }

    die usage() unless defined $opt{target_dir};

    my $exists = ($IS_WINDOWS && $USE_LONGPATH)
        ? testL('d', $opt{target_dir})
        : -d $opt{target_dir};

    die "エラー: フォルダが見つかりません: $opt{target_dir}\n" unless $exists;

    return \%opt;
}

sub parse_depth_arg {
    my ($value, $opt_name) = @_;

    die "エラー: $opt_name の値がありません\n" unless defined $value;
    die "エラー: $opt_name には 0 以上の整数を指定してください\n"
        unless $value =~ /\A\d+\z/;

    return int($value);
}

sub usage {
    return <<"USAGE";
使い方:
  perl dupdel.pl 対象フォルダ
  perl dupdel.pl --delete 対象フォルダ
  perl dupdel.pl -d N 対象フォルダ
  perl dupdel.pl -D N 対象フォルダ
  perl dupdel.pl -p STRING 対象フォルダ
  perl dupdel.pl -r 対象フォルダ
  perl dupdel.pl -p STRING -r 対象フォルダ
  perl dupdel.pl -d N -s 対象フォルダ
  perl dupdel.pl -D N -s 対象フォルダ

説明:
  --delete を付けない場合は dry-run です（削除しません）。
  指定フォルダ直下の通常ファイルのみを対象に、重複ファイルを検出します。
  -d N はちょうど N 階層下の各フォルダを独立に処理します。
       N=0 のときは葉フォルダのみを処理します。
  -D N は 1 階層下から N 階層下までの各フォルダを独立に処理します。
       N=0 のときはすべてのサブフォルダを処理します。
  -s を付けると基準フォルダ自身も処理対象に含めます。
  -p STRING を付けると STRING を含むファイルを削除側へ寄せます。
  -r を付けるとファイル名の逆順で keep を決めます。
USAGE
}

sub process_target_dirs {
    my ($target_dirs, $opt, $log_fh) = @_;

    my $overall = empty_result();
    my $show_dir_header = @$target_dirs > 1;

    if (!@$target_dirs) {
        print_cp932("処理対象フォルダがありません。\n");
        log_utf8($log_fh, "処理対象フォルダがありません。\n") if $opt->{do_delete};
        return $overall;
    }

    for my $dir (@$target_dirs) {
        my $result = process_duplicates_in_dir($dir, $opt, $log_fh, $show_dir_header);

        $overall->{processed_dirs}++;
        $overall->{total_files}        += $result->{total_files};
        $overall->{duplicate_groups}   += $result->{duplicate_groups};
        $overall->{delete_candidates}  += $result->{delete_candidates};
        $overall->{deleted_count}      += $result->{deleted_count};
        $overall->{delete_error_count} += $result->{delete_error_count};
        $overall->{hash_error_count}   += $result->{hash_error_count};
        push @{ $overall->{delete_failures} }, @{ $result->{delete_failures} };
    }

    return $overall;
}

sub process_duplicates_in_dir {
    my ($dir, $opt, $log_fh, $show_dir_header) = @_;
    my $do_delete = $opt->{do_delete};

    my $result = empty_result();
    my @files = collect_files($dir);
    $result->{total_files} = scalar @files;

    if ($show_dir_header) {
        print_cp932("===== $dir =====\n");
    }

    if ($do_delete) {
        log_utf8($log_fh, "TARGET_DIR: $dir\n");
    }

    my %by_size;
    for my $f (@files) {
        push @{ $by_size{ $f->{size} } }, $f;
    }

    my @dup_groups;

    for my $size (sort { $a <=> $b } keys %by_size) {
        my $same_size_files = $by_size{$size};
        next if @$same_size_files < 2;

        my %by_sha1;
        for my $f (@$same_size_files) {
            my $sha1 = calc_sha1($f->{path});
            if (!defined $sha1) {
                $result->{hash_error_count}++;
                print_cp932("HASH失敗: $f->{name}\n");
                log_utf8($log_fh, "HASH失敗: $f->{name}\n") if $do_delete;
                next;
            }
            push @{ $by_sha1{$sha1} }, $f;
        }

        for my $sha1 (sort keys %by_sha1) {
            my $dups = $by_sha1{$sha1};
            next if @$dups < 2;

            my @sorted = sort_duplicate_group($dups, $opt);
            my $keep = shift @sorted;

            push @dup_groups, {
                keep => $keep,
                dels => [ @sorted ],
            };
        }
    }

    @dup_groups = sort { $a->{keep}{name} cmp $b->{keep}{name} } @dup_groups;

    if (!@dup_groups) {
        if ($show_dir_header) {
            print_cp932("(重複なし)\n\n");
        }
        if ($do_delete) {
            log_utf8($log_fh, "(重複なし)\n");
            log_utf8($log_fh, "件数: 対象=$result->{total_files} / 重複組=0 / 削除候補=0 / 削除成功=0 / 削除失敗=0 / HASH失敗=$result->{hash_error_count}\n\n");
        }
        return $result;
    }

    for my $group (@dup_groups) {
        my $keep = $group->{keep};
        my @sorted = @{ $group->{dels} };

        $result->{duplicate_groups}++;
        $result->{delete_candidates} += scalar @sorted;

        print_cp932("$keep->{name}\n");
        for my $del (@sorted) {
            print_cp932("-> $del->{name}\n");
        }
        print_cp932("\n");

        if ($do_delete) {
            log_utf8($log_fh, "$keep->{name}\n");

            for my $del (@sorted) {
                my $ok = delete_file($del->{path});

                if ($ok) {
                    $result->{deleted_count}++;
                    log_utf8($log_fh, "-> $del->{name}\n");
                }
                else {
                    my $error_message = $!;
                    my $failed_at = timestamp_for_log();
                    $result->{delete_error_count}++;
                    push @{ $result->{delete_failures} }, {
                        target_dir => $dir,
                        keep_name  => $keep->{name},
                        delete_name => $del->{name},
                        error      => $error_message,
                        failed_at  => $failed_at,
                    };
                    warn_cp932("削除失敗: keep=$keep->{name} / delete=$del->{name} : $error_message\n");
                    log_utf8($log_fh, "-> $del->{name} [削除失敗: $error_message]\n");
                }
            }

            log_utf8($log_fh, "\n");
        }
    }

    if ($do_delete) {
        log_utf8($log_fh, "件数: 対象=$result->{total_files} / 重複組=$result->{duplicate_groups} / 削除候補=$result->{delete_candidates} / 削除成功=$result->{deleted_count} / 削除失敗=$result->{delete_error_count} / HASH失敗=$result->{hash_error_count}\n\n");
    }

    return $result;
}

sub collect_target_dirs {
    my ($base_dir, $opt) = @_;

    if (!defined $opt->{exact_depth} && !defined $opt->{max_depth}) {
        return ($base_dir);
    }

    if (defined $opt->{exact_depth} && $opt->{exact_depth} == 0) {
        my @dirs;
        push @dirs, $base_dir if $opt->{include_self};
        push @dirs, collect_leaf_subdirs($base_dir);
        return @dirs;
    }

    if (defined $opt->{max_depth} && $opt->{max_depth} == 0) {
        my @dirs;
        push @dirs, $base_dir if $opt->{include_self};
        push @dirs, collect_all_subdirs($base_dir);
        return @dirs;
    }

    my $min_depth = defined $opt->{exact_depth} ? $opt->{exact_depth} : 1;
    my $max_depth = defined $opt->{exact_depth} ? $opt->{exact_depth} : $opt->{max_depth};

    my @dirs;
    push @dirs, $base_dir if $opt->{include_self};
    push @dirs, collect_subdirs_in_range($base_dir, $min_depth, $max_depth);

    return @dirs;
}

sub sort_duplicate_group {
    my ($dups, $opt) = @_;

    return sort {
        my $prio_cmp = priority_delete_rank($a->{name}, $opt)
            <=> priority_delete_rank($b->{name}, $opt);
        return $prio_cmp if $prio_cmp != 0;

        return $opt->{reverse_keep}
            ? ($b->{name} cmp $a->{name})
            : ($a->{name} cmp $b->{name});
    } @$dups;
}

sub priority_delete_rank {
    my ($name, $opt) = @_;

    return 0 unless defined $opt->{priority_delete};
    return file_matches_priority_delete($name, $opt->{priority_delete}) ? 1 : 0;
}

sub file_matches_priority_delete {
    my ($name, $needle) = @_;

    return 0 unless defined $needle;
    return index($name, $needle) >= 0 ? 1 : 0;
}

sub collect_subdirs_in_range {
    my ($dir, $min_depth, $max_depth) = @_;

    my @out;
    _collect_subdirs_in_range($dir, 1, $min_depth, $max_depth, \@out);
    return @out;
}

sub collect_all_subdirs {
    my ($dir) = @_;

    my @out;
    _collect_all_subdirs($dir, \@out);
    return @out;
}

sub _collect_all_subdirs {
    my ($dir, $out) = @_;

    for my $subdir (collect_subdirs($dir)) {
        push @$out, $subdir;
        _collect_all_subdirs($subdir, $out);
    }
}

sub collect_leaf_subdirs {
    my ($dir) = @_;

    my @out;
    _collect_leaf_subdirs($dir, \@out);
    return @out;
}

sub _collect_leaf_subdirs {
    my ($dir, $out) = @_;

    for my $subdir (collect_subdirs($dir)) {
        my @children = collect_subdirs($subdir);
        if (@children) {
            _collect_leaf_subdirs($subdir, $out);
        }
        else {
            push @$out, $subdir;
        }
    }
}

sub _collect_subdirs_in_range {
    my ($dir, $depth, $min_depth, $max_depth, $out) = @_;

    return if $depth > $max_depth;

    for my $subdir (collect_subdirs($dir)) {
        push @$out, $subdir if $depth >= $min_depth;
        _collect_subdirs_in_range($subdir, $depth + 1, $min_depth, $max_depth, $out)
            if $depth < $max_depth;
    }
}

sub collect_subdirs {
    my ($dir) = @_;

    if ($IS_WINDOWS && $USE_LONGPATH) {
        return collect_subdirs_longpath($dir);
    }
    else {
        return collect_subdirs_core($dir);
    }
}

sub collect_subdirs_longpath {
    my ($dir) = @_;

    my $dh = Win32::LongPath->new();
    $dh->opendirL($dir) or die "フォルダを開けません: $dir ($^E)\n";

    my @dirs;

    for my $name (sort $dh->readdirL()) {
        next if $name eq '.';
        next if $name eq '..';

        my $path = File::Spec->catdir($dir, $name);
        next unless testL('d', $path);

        push @dirs, $path;
    }

    $dh->closedirL();
    return @dirs;
}

sub collect_subdirs_core {
    my ($dir) = @_;

    opendir my $dh, $dir
        or die "フォルダを開けません: $dir\n";

    my @dirs;

    while (my $name = readdir $dh) {
        next if $name eq '.';
        next if $name eq '..';

        my $path = File::Spec->catdir($dir, $name);
        next unless -d $path;

        push @dirs, $path;
    }

    closedir $dh;
    return sort @dirs;
}

sub collect_files {
    my ($dir) = @_;

    if ($IS_WINDOWS && $USE_LONGPATH) {
        return collect_files_longpath($dir);
    }
    else {
        return collect_files_core($dir);
    }
}

sub collect_files_longpath {
    my ($dir) = @_;

    my $dh = Win32::LongPath->new();
    $dh->opendirL($dir) or die "フォルダを開けません: $dir ($^E)\n";

    my @files;

    for my $name (sort $dh->readdirL()) {
        next if $name eq '.';
        next if $name eq '..';

        my $path = File::Spec->catfile($dir, $name);
        next unless testL('f', $path);

        my $st = statL($path);
        next unless $st;
        next unless defined $st->{size};

        push @files, {
            name => $name,
            path => $path,
            size => $st->{size},
        };
    }

    $dh->closedirL();
    return @files;
}

sub collect_files_core {
    my ($dir) = @_;

    opendir my $dh, $dir
        or die "フォルダを開けません: $dir\n";

    my @files;

    while (my $name = readdir $dh) {
        next if $name eq '.';
        next if $name eq '..';

        my $path = File::Spec->catfile($dir, $name);
        next unless -f $path;

        push @files, {
            name => $name,
            path => $path,
            size => -s $path,
        };
    }

    closedir $dh;
    return sort { $a->{name} cmp $b->{name} } @files;
}

sub calc_sha1 {
    my ($path) = @_;

    my $fh;
    my $ok;

    if ($IS_WINDOWS && $USE_LONGPATH) {
        $ok = openL(\$fh, '<:raw', $path);
    }
    else {
        $ok = open($fh, '<:raw', $path);
    }

    return undef unless $ok;

    my $sha = Digest::SHA->new(1);
    $sha->addfile($fh);
    close $fh;

    return $sha->hexdigest;
}

sub delete_file {
    my ($path) = @_;

    if ($IS_WINDOWS && $USE_LONGPATH) {
        return unlinkL($path);
    }
    else {
        return unlink($path);
    }
}

sub empty_result {
    return {
        processed_dirs      => 0,
        total_files         => 0,
        duplicate_groups    => 0,
        delete_candidates   => 0,
        deleted_count       => 0,
        delete_error_count  => 0,
        hash_error_count    => 0,
        delete_failures     => [],
    };
}

sub log_delete_failures_summary {
    my ($log_fh, $delete_failures) = @_;

    return unless $log_fh;
    return unless $delete_failures && @$delete_failures;

    log_utf8($log_fh, "削除失敗一覧:\n");

    for my $failure (@$delete_failures) {
        log_utf8($log_fh, "- TARGET_DIR: $failure->{target_dir}\n");
        log_utf8($log_fh, "  KEEP: $failure->{keep_name}\n");
        log_utf8($log_fh, "  DELETE: $failure->{delete_name}\n");
        log_utf8($log_fh, "  ERROR: $failure->{error}\n");
        log_utf8($log_fh, "  TIME: $failure->{failed_at}\n");
    }

    log_utf8($log_fh, "\n");
}

sub open_log_file {
    my ($log_file) = @_;

    my $needs_separator = (-e $log_file && -s $log_file) ? 1 : 0;

    open my $log_fh, '>>:encoding(UTF-8)', $log_file
        or die "ログファイルを開けません: $log_file\n";

    log_utf8($log_fh, "\n") if $needs_separator;
    return $log_fh;
}

sub log_utf8 {
    my ($fh, $text) = @_;
    print {$fh} to_log_text($text);
}

sub to_log_text {
    my ($text) = @_;
    return '' unless defined $text;
    return $text if utf8::is_utf8($text);

    return eval { decode('cp932', $text, 1) } // $text;
}

sub target_mode_label {
    my ($opt) = @_;

    if (defined $opt->{exact_depth}) {
        if ($opt->{exact_depth} == 0) {
            return $opt->{include_self}
                ? "基準 + 葉フォルダのみ"
                : "葉フォルダのみ";
        }
        return $opt->{include_self}
            ? "基準 + ちょうど $opt->{exact_depth} 階層下"
            : "ちょうど $opt->{exact_depth} 階層下";
    }

    if (defined $opt->{max_depth}) {
        if ($opt->{max_depth} == 0) {
            return $opt->{include_self}
                ? "基準 + 全サブフォルダ"
                : "全サブフォルダ";
        }
        return $opt->{include_self}
            ? "基準 + 1..$opt->{max_depth} 階層下"
            : "1..$opt->{max_depth} 階層下";
    }

    return "基準フォルダ直下のみ";
}

sub keep_rule_label {
    my ($opt) = @_;

    my $order = $opt->{reverse_keep} ? '逆順' : '通常順';
    return defined $opt->{priority_delete}
        ? "$order / 優先削除='$opt->{priority_delete}'"
        : $order;
}

sub make_log_filename {
    my @lt = localtime;
    return sprintf(
        '%04d%02d%02d-DUPDEL.log',
        $lt[5] + 1900,
        $lt[4] + 1,
        $lt[3],
    );
}

sub timestamp_for_log {
    my @lt = localtime;
    return sprintf(
        '%04d-%02d-%02d %02d:%02d:%02d',
        $lt[5] + 1900,
        $lt[4] + 1,
        $lt[3],
        $lt[2],
        $lt[1],
        $lt[0],
    );
}
