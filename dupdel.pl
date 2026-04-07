use strict;
use warnings;
use utf8;

use FindBin;
use lib $FindBin::Bin;

use Digest::SHA;
use Encode qw(decode encode FB_CROAK);
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
    my $opt = parse_args(decode_cli_args(@ARGV));
    my @target_dirs = $opt->{folder_mode}
        ? ($opt->{target_dir})
        : collect_target_dirs($opt->{target_dir}, $opt);
    my $log_file = make_log_filename();

    print_cp932("モード         : " . ($opt->{do_delete} ? "実削除" : "dry-run") . "\n");
    print_cp932("基準フォルダ   : $opt->{target_dir}\n");
    print_cp932("処理単位       : " . target_mode_label($opt) . "\n");
    print_cp932("処理対象数     : " . scalar(@target_dirs) . "\n");
    print_cp932("keep選択       : " . keep_rule_label($opt) . "\n");
    print_cp932("削除除外       : " . exclude_rule_label($opt) . "\n");
    print_cp932("ハッシュ方式   : $opt->{hash_alg}\n");
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
        log_utf8($log_fh, "KEEP_RULE: " . keep_rule_label($opt) . "\n");
        log_utf8($log_fh, "HASH_ALG: $opt->{hash_alg}\n");
        log_utf8($log_fh, "EXCLUDE_RULE: " . exclude_rule_label($opt) . "\n\n");
    }

    my $result = $opt->{folder_mode}
        ? process_duplicate_folders($opt->{target_dir}, $opt, $log_fh)
        : process_target_dirs(\@target_dirs, $opt, $log_fh);

    if ($opt->{do_delete}) {
        log_delete_failures_summary($log_fh, $result->{delete_failures});
        if ($opt->{folder_mode}) {
            log_folder_summary($log_fh, "合計件数", $result);
        }
        else {
            log_file_summary($log_fh, "合計件数", $result);
        }
        log_utf8($log_fh, "===== " . timestamp_for_log() . " END =====\n");
        close $log_fh;
    }

    print_cp932("\n");
    print_cp932("===== 実行結果 =====\n");
    if ($opt->{folder_mode}) {
        print_folder_result($result);
    }
    else {
        print_file_result($result);
    }

    if (!$opt->{do_delete}) {
        print_cp932("\n");
        print_cp932("※ dry-run です。実際には削除していません。\n");
        print_cp932("  実際に削除するには --delete を付けて実行してください。\n");
    }
}

sub decode_cli_args {
    my @args = @_;

    return @args unless $IS_WINDOWS;
    return map { decode_cli_arg($_) } @args;
}

sub decode_cli_arg {
    my ($arg) = @_;

    return $arg unless defined $arg;

    if (utf8::is_utf8($arg)) {
        return $arg unless $arg =~ /[\x{0080}-\x{00ff}]/;

        my $bytes = eval { encode('latin-1', $arg, FB_CROAK) };
        return $arg unless defined $bytes;

        return eval { decode('cp932', $bytes, FB_CROAK) } // $arg;
    }

    return eval { decode('cp932', $arg, FB_CROAK) } // $arg;
}

sub parse_args {
    my @args = @_;

    my %opt = (
        do_delete    => 0,
        include_self => 0,
        reverse_keep => 0,
        hash_alg     => 'sha256',
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
        elsif ($arg eq '-F') {
            $opt{folder_mode} = 1;
        }
        elsif ($arg eq '--verbose' || $arg eq '-v') {
            $opt{verbose} = 1;
        }
        elsif ($arg eq '--hash' || $arg eq '-H') {
            die usage() unless @args;
            $opt{hash_alg} = normalize_hash_alg(shift @args);
        }
        elsif ($arg eq '-p') {
            die usage() unless @args;
            $opt{priority_delete} = shift @args;
        }
        elsif ($arg eq '-e') {
            die usage() unless @args;
            $opt{exclude_regex_text} = shift @args;
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
    $opt{hash_alg} = normalize_hash_alg($opt{hash_alg});

    if ($opt{folder_mode}) {
        die "エラー: -F と -d は同時に指定できません\n" if defined $opt{exact_depth};
        die "エラー: -F と -D は同時に指定できません\n" if defined $opt{max_depth};
        die "エラー: -F と -s は同時に指定できません\n" if $opt{include_self};
        die "エラー: -F と -p は同時に指定できません\n" if defined $opt{priority_delete};
    }

    if (defined $opt{exclude_regex_text}) {
        $opt{exclude_regex} = compile_exclude_regex($opt{exclude_regex_text});
    }

    init_hash_algorithm($opt{hash_alg});

    my $exists = ($IS_WINDOWS && $USE_LONGPATH)
        ? testL('d', $opt{target_dir})
        : -d $opt{target_dir};

    die "エラー: フォルダが見つかりません: $opt{target_dir}\n" unless $exists;

    return \%opt;
}

sub normalize_hash_alg {
    my ($alg) = @_;

    die "エラー: --hash には sha1 / sha256 / blake2 / blake3 のいずれかを指定してください\n"
        unless defined $alg && length $alg;

    $alg = lc $alg;
    die "エラー: 未対応のハッシュ方式です: $alg (指定可能: sha1 / sha256 / blake2 / blake3)\n"
        unless $alg =~ /\A(?:sha1|sha256|blake2|blake3)\z/;

    return $alg;
}

sub init_hash_algorithm {
    my ($alg) = @_;

    if ($alg eq 'sha1' || $alg eq 'sha256') {
        return;
    }

    if ($alg eq 'blake2') {
        eval {
            require Crypt::Digest;
            1;
        } or die "エラー: blake2 を使うには CryptX の Crypt::Digest が必要です\n";
        return;
    }

    if ($alg eq 'blake3') {
        eval {
            require Digest::BLAKE3;
            1;
        } or die "エラー: blake3 を使うには Digest::BLAKE3 が必要です\n";
        return;
    }
}

sub compile_exclude_regex {
    my ($pattern) = @_;

    die "エラー: -e の正規表現が空です\n"
        unless defined $pattern && length $pattern;

    my $regex = eval { qr/$pattern/ };
    die "エラー: -e の正規表現が不正です: $@\n" if $@;

    return $regex;
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
  perl dupdel.pl -F 対象フォルダ
  perl dupdel.pl -F --delete 対象フォルダ
  perl dupdel.pl --verbose 対象フォルダ
  perl dupdel.pl -v 対象フォルダ
  perl dupdel.pl --hash ALG 対象フォルダ
  perl dupdel.pl -H ALG 対象フォルダ
  perl dupdel.pl -d N 対象フォルダ
  perl dupdel.pl -D N 対象フォルダ
  perl dupdel.pl -p STRING 対象フォルダ
  perl dupdel.pl -e REGEX 対象フォルダ
  perl dupdel.pl -r 対象フォルダ
  perl dupdel.pl -p STRING -r 対象フォルダ
  perl dupdel.pl -e REGEX -p STRING -r 対象フォルダ
  perl dupdel.pl -d N -s 対象フォルダ
  perl dupdel.pl -D N -s 対象フォルダ

説明:
  --delete を付けない場合は dry-run です（削除しません）。
  指定フォルダ直下の通常ファイルのみを対象に、重複ファイルを検出します。
  --verbose または -v を付けると、複数フォルダ処理時に重複なしフォルダも画面表示します。
  ハッシュ方式のデフォルトは sha256 です。
  --hash ALG または -H ALG でハッシュ方式を指定できます。
       ALG は sha1 / sha256 / blake2 / blake3 のいずれかです。
       blake2 は CryptX の Crypt::Digest、blake3 は Digest::BLAKE3 が必要です。
  -F を付けると対象フォルダ直下の子フォルダ同士を比較し、完全一致した重複フォルダを検出します。
       フォルダ比較は直下ファイルのみを対象にし、サブフォルダを含む子フォルダはスキップします。
       実削除時は delete 側フォルダ内のファイルを削除し、空になった場合のみフォルダを削除します。
  -d N はちょうど N 階層下の各フォルダを独立に処理します。
       N=0 のときは葉フォルダのみを処理します。
  -D N は 1 階層下から N 階層下までの各フォルダを独立に処理します。
       N=0 のときはすべてのサブフォルダを処理します。
  -s を付けると基準フォルダ自身も処理対象に含めます。
  -p STRING を付けると STRING を含むファイルを削除側へ寄せます。
  -e REGEX を付けるとファイル名が REGEX にマッチするファイルを削除候補から除外します。
       REGEX はフルパスではなくファイル名だけに対して判定します。
       除外にマッチしたファイルは重複していても削除しません。
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
        $overall->{delete_size_planned} += $result->{delete_size_planned};
        $overall->{delete_size_done}    += $result->{delete_size_done};
        $overall->{delete_size_failed}  += $result->{delete_size_failed};
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

        my %by_hash;
        for my $f (@$same_size_files) {
            my $hash = calc_file_hash($f->{path}, $opt);
            if (!defined $hash) {
                $result->{hash_error_count}++;
                print_cp932("HASH失敗: $f->{name}\n");
                log_utf8($log_fh, "HASH失敗: $f->{name}\n") if $do_delete;
                next;
            }
            push @{ $by_hash{$hash} }, $f;
        }

        for my $hash (sort keys %by_hash) {
            my $dups = $by_hash{$hash};
            next if @$dups < 2;

            push @dup_groups, build_duplicate_group($dups, $opt);
        }
    }

    @dup_groups = sort { $a->{keep}{name} cmp $b->{keep}{name} } @dup_groups;

    if (!@dup_groups) {
        if ($show_dir_header && $opt->{verbose}) {
            print_cp932("===== $dir =====\n");
            print_cp932("(重複なし)\n\n");
        }
        if ($do_delete) {
            log_utf8($log_fh, "(重複なし)\n");
            log_file_summary($log_fh, "件数", $result);
        }
        return $result;
    }

    if ($show_dir_header) {
        print_cp932("===== $dir =====\n");
    }

    for my $group (@dup_groups) {
        my $keep = $group->{keep};
        my @sorted = @{ $group->{dels} };
        my @excluded = @{ $group->{excluded} };

        $result->{duplicate_groups}++;
        $result->{delete_candidates} += scalar @sorted;
        $result->{delete_size_planned} += $_->{size} for @sorted;

        if ($group->{keep_is_excluded}) {
            print_cp932("除外: $keep->{name}\n");
        }
        else {
            print_cp932("$keep->{name}\n");
        }
        for my $del (@sorted) {
            print_cp932("-> $del->{name}\n");
        }
        for my $excluded (@excluded) {
            print_cp932("除外: $excluded->{name}\n");
        }
        print_cp932("\n");

        if ($do_delete) {
            if ($group->{keep_is_excluded}) {
                log_utf8($log_fh, "除外: $keep->{name}\n");
            }
            else {
                log_utf8($log_fh, "$keep->{name}\n");
            }

            for my $del (@sorted) {
                my $ok = delete_file($del->{path});

                if ($ok) {
                    $result->{deleted_count}++;
                    $result->{delete_size_done} += $del->{size};
                    log_utf8($log_fh, "-> $del->{name}\n");
                }
                else {
                    my $error_message = $!;
                    my $failed_at = timestamp_for_log();
                    $result->{delete_error_count}++;
                    $result->{delete_size_failed} += $del->{size};
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

            for my $excluded (@excluded) {
                log_utf8($log_fh, "除外: $excluded->{name}\n");
            }

            log_utf8($log_fh, "\n");
        }
    }

    if ($do_delete) {
        log_file_summary($log_fh, "件数", $result);
    }

    return $result;
}

sub process_duplicate_folders {
    my ($base_dir, $opt, $log_fh) = @_;
    my $do_delete = $opt->{do_delete};

    my $result = empty_result();
    $result->{processed_dirs} = 1;

    log_utf8($log_fh, "TARGET_DIR: $base_dir\n") if $do_delete;

    my @child_dirs = map {
        {
            name => path_basename($_),
            path => $_,
        }
    } collect_subdirs($base_dir);

    $result->{target_dirs} = scalar @child_dirs;

    my %by_signature;

    for my $entry (@child_dirs) {
        my @subdirs = collect_subdirs($entry->{path});
        if (@subdirs) {
            $result->{skipped_subdir_dirs}++;
            print_cp932("スキップ: $entry->{name} (サブフォルダを含むためスキップ)\n");
            log_utf8($log_fh, "スキップ: $entry->{name} (サブフォルダを含むためスキップ)\n") if $do_delete;
            next;
        }

        my $signature = folder_signature($entry, $opt, $result, $log_fh, $do_delete);
        next unless defined $signature;

        push @{ $by_signature{$signature} }, $entry;
    }

    my @dup_groups;
    for my $signature (sort keys %by_signature) {
        my $entries = $by_signature{$signature};
        next if @$entries < 2;

        my @sorted = sort_folder_entries($entries, $opt);
        my $keep = shift @sorted;

        push @dup_groups, {
            keep => $keep,
            dels => [ @sorted ],
        };
    }

    @dup_groups = sort { $a->{keep}{name} cmp $b->{keep}{name} } @dup_groups;

    if (!@dup_groups) {
        print_cp932("(重複フォルダなし)\n");
        log_utf8($log_fh, "(重複フォルダなし)\n") if $do_delete;
        return $result;
    }

    for my $group (@dup_groups) {
        my $keep = $group->{keep};
        my @dels = @{ $group->{dels} };
        my $has_exclude = folder_group_has_excluded_file($group, $opt);
        my $delete_size = 0;
        $delete_size += $_->{total_size} for @dels;

        $result->{duplicate_groups}++;

        print_cp932("$keep->{name}\n");
        log_utf8($log_fh, "$keep->{name}\n") if $do_delete;

        for my $del (@dels) {
            print_cp932("-> $del->{name} ($del->{total_size} bytes)\n");
            log_utf8($log_fh, "-> $del->{name} ($del->{total_size} bytes)\n") if $do_delete;
        }

        if ($has_exclude) {
            $result->{skipped_exclude_groups}++;
            print_cp932("削除スキップ: 除外 regex にマッチするファイルを含むため、フォルダグループ全体をスキップ\n\n");
            log_utf8($log_fh, "削除スキップ: 除外 regex にマッチするファイルを含むため、フォルダグループ全体をスキップ\n\n") if $do_delete;
            next;
        }

        $result->{delete_candidates} += scalar @dels;
        $result->{delete_size_planned} += $delete_size;
        print_cp932("削除予定サイズ: $delete_size bytes\n\n");
        log_utf8($log_fh, "削除予定サイズ: $delete_size bytes\n\n") if $do_delete;

        next unless $do_delete;

        for my $del (@dels) {
            delete_duplicate_folder_entry($keep, $del, $result, $log_fh);
        }
    }

    return $result;
}

sub folder_signature {
    my ($entry, $opt, $result, $log_fh, $do_delete) = @_;

    my @files = collect_files($entry->{path});
    my @parts;
    my $total_size = 0;

    for my $file (@files) {
        my $hash = calc_file_hash($file->{path}, $opt);
        if (!defined $hash) {
            $result->{hash_error_count}++;
            print_cp932("HASH失敗: $entry->{name}/$file->{name}\n");
            log_utf8($log_fh, "HASH失敗: $entry->{name}/$file->{name}\n") if $do_delete;
            return undef;
        }

        push @parts, join("\0", $file->{name}, $file->{size}, $hash);
        $total_size += $file->{size};
    }

    $entry->{files} = [ @files ];
    $entry->{total_size} = $total_size;
    $result->{total_files} += scalar @files;

    return join("\0\0", sort @parts);
}

sub sort_folder_entries {
    my ($entries, $opt) = @_;

    return sort {
        $opt->{reverse_keep}
            ? ($b->{name} cmp $a->{name})
            : ($a->{name} cmp $b->{name})
    } @$entries;
}

sub folder_group_has_excluded_file {
    my ($group, $opt) = @_;

    return 0 unless defined $opt->{exclude_regex};

    for my $entry ($group->{keep}, @{ $group->{dels} }) {
        for my $file (@{ $entry->{files} }) {
            return 1 if file_matches_exclude_regex($file->{name}, $opt);
        }
    }

    return 0;
}

sub delete_duplicate_folder_entry {
    my ($keep, $del, $result, $log_fh) = @_;

    for my $file (@{ $del->{files} }) {
        my $ok = delete_file($file->{path});
        if ($ok) {
            $result->{delete_size_done} += $file->{size};
            log_utf8($log_fh, "   file deleted: $file->{name} ($file->{size} bytes)\n");
        }
        else {
            my $error_message = $!;
            my $failed_at = timestamp_for_log();
            $result->{delete_error_count}++;
            $result->{delete_size_failed} += $file->{size};
            push @{ $result->{delete_failures} }, {
                target_dir => $del->{path},
                keep_name  => $keep->{name},
                delete_name => "$del->{name}/$file->{name}",
                error      => $error_message,
                failed_at  => $failed_at,
            };
            warn_cp932("削除失敗: keep=$keep->{name} / delete=$del->{name}/$file->{name} : $error_message\n");
            log_utf8($log_fh, "   file delete failed: $file->{name} ($error_message)\n");
        }
    }

    if (!dir_is_empty($del->{path})) {
        my $error_message = "フォルダが空ではありません";
        my $failed_at = timestamp_for_log();
        $result->{delete_error_count}++;
        push @{ $result->{delete_failures} }, {
            target_dir => $del->{path},
            keep_name  => $keep->{name},
            delete_name => $del->{name},
            error      => $error_message,
            failed_at  => $failed_at,
        };
        warn_cp932("フォルダ削除スキップ: $del->{name} ($error_message)\n");
        log_utf8($log_fh, "   folder delete skipped: $error_message\n");
        return;
    }

    my $ok = remove_empty_dir($del->{path});
    if ($ok) {
        $result->{deleted_count}++;
        log_utf8($log_fh, "   folder deleted: $del->{name}\n");
    }
    else {
        my $error_message = $!;
        my $failed_at = timestamp_for_log();
        $result->{delete_error_count}++;
        push @{ $result->{delete_failures} }, {
            target_dir => $del->{path},
            keep_name  => $keep->{name},
            delete_name => $del->{name},
            error      => $error_message,
            failed_at  => $failed_at,
        };
        warn_cp932("フォルダ削除失敗: keep=$keep->{name} / delete=$del->{name} : $error_message\n");
        log_utf8($log_fh, "   folder delete failed: $error_message\n");
    }
}

sub dir_is_empty {
    my ($dir) = @_;

    if ($IS_WINDOWS && $USE_LONGPATH) {
        return dir_is_empty_longpath($dir);
    }
    else {
        return dir_is_empty_core($dir);
    }
}

sub dir_is_empty_longpath {
    my ($dir) = @_;

    my $dh = Win32::LongPath->new();
    $dh->opendirL($dir) or return 0;

    for my $name ($dh->readdirL()) {
        next if $name eq '.';
        next if $name eq '..';

        $dh->closedirL();
        return 0;
    }

    $dh->closedirL();
    return 1;
}

sub dir_is_empty_core {
    my ($dir) = @_;

    opendir my $dh, $dir or return 0;

    while (my $name = readdir $dh) {
        next if $name eq '.';
        next if $name eq '..';

        closedir $dh;
        return 0;
    }

    closedir $dh;
    return 1;
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

sub build_duplicate_group {
    my ($dups, $opt) = @_;

    my @excluded = sort_duplicate_group(
        [ grep { file_matches_exclude_regex($_->{name}, $opt) } @$dups ],
        $opt,
    );
    my @eligible = sort_duplicate_group(
        [ grep { !file_matches_exclude_regex($_->{name}, $opt) } @$dups ],
        $opt,
    );

    my $keep_is_excluded = @eligible ? 0 : 1;
    my $keep = @eligible ? shift @eligible : shift @excluded;

    return {
        keep             => $keep,
        dels             => [ @eligible ],
        excluded         => [ @excluded ],
        keep_is_excluded => $keep_is_excluded,
    };
}

sub priority_delete_rank {
    my ($name, $opt) = @_;

    return 0 unless defined $opt->{priority_delete};
    return file_matches_priority_delete($name, $opt->{priority_delete}) ? 1 : 0;
}

sub file_matches_exclude_regex {
    my ($name, $opt) = @_;

    return 0 unless defined $opt->{exclude_regex};
    return $name =~ $opt->{exclude_regex} ? 1 : 0;
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

sub calc_file_hash {
    my ($path, $opt) = @_;

    my $fh;
    my $ok;

    if ($IS_WINDOWS && $USE_LONGPATH) {
        $ok = openL(\$fh, '<:raw', $path);
    }
    else {
        $ok = open($fh, '<:raw', $path);
    }

    return undef unless $ok;

    my $digest = new_hash_context($opt->{hash_alg});
    my $buffer = '';

    while (1) {
        my $read_len = read($fh, $buffer, 1024 * 1024);
        if (!defined $read_len) {
            close $fh;
            return undef;
        }
        last if $read_len == 0;

        $digest->add($buffer);
    }

    close $fh;

    return digest_to_hex($digest);
}

sub new_hash_context {
    my ($alg) = @_;

    if ($alg eq 'sha1') {
        return Digest::SHA->new(1);
    }
    if ($alg eq 'sha256') {
        return Digest::SHA->new(256);
    }
    if ($alg eq 'blake2') {
        return Crypt::Digest->new('BLAKE2b_256');
    }
    if ($alg eq 'blake3') {
        my $digest = Digest::BLAKE3::->new_hash();
        $digest->hashsize(256) if $digest->can('hashsize');
        return $digest;
    }

    die "エラー: 未対応のハッシュ方式です: $alg\n";
}

sub digest_to_hex {
    my ($digest) = @_;

    return $digest->hexdigest() if $digest->can('hexdigest');
    return unpack('H*', $digest->digest()) if $digest->can('digest');

    die "エラー: ハッシュ値を取り出せません\n";
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

sub remove_empty_dir {
    my ($path) = @_;

    if ($IS_WINDOWS && $USE_LONGPATH) {
        return rmdirL($path);
    }
    else {
        return rmdir($path);
    }
}

sub path_basename {
    my ($path) = @_;

    my @parts = File::Spec->splitdir($path);
    pop @parts while @parts && $parts[-1] eq '';
    return @parts ? $parts[-1] : $path;
}

sub empty_result {
    return {
        processed_dirs      => 0,
        target_dirs         => 0,
        total_files         => 0,
        duplicate_groups    => 0,
        delete_candidates   => 0,
        deleted_count       => 0,
        delete_error_count  => 0,
        hash_error_count    => 0,
        skipped_subdir_dirs => 0,
        skipped_exclude_groups => 0,
        delete_size_planned => 0,
        delete_size_done    => 0,
        delete_size_failed  => 0,
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

sub print_file_result {
    my ($result) = @_;

    print_cp932("処理フォルダ数     : $result->{processed_dirs}\n");
    print_cp932("対象ファイル数     : $result->{total_files}\n");
    print_cp932("重複グループ数     : $result->{duplicate_groups}\n");
    print_cp932("削除候補数         : $result->{delete_candidates}\n");
    print_cp932("削除実行数         : $result->{deleted_count}\n");
    print_cp932("削除失敗数         : $result->{delete_error_count}\n");
    print_cp932("ハッシュ失敗数     : $result->{hash_error_count}\n");
    print_cp932("削除予定サイズ合計 : $result->{delete_size_planned} bytes\n");
    print_cp932("実削除サイズ合計   : $result->{delete_size_done} bytes\n");
    print_cp932("削除失敗サイズ合計 : $result->{delete_size_failed} bytes\n");
}

sub print_folder_result {
    my ($result) = @_;

    print_cp932("比較対象候補フォルダ数 : $result->{target_dirs}\n");
    print_cp932("対象ファイル数         : $result->{total_files}\n");
    print_cp932("重複フォルダグループ数 : $result->{duplicate_groups}\n");
    print_cp932("削除候補フォルダ数     : $result->{delete_candidates}\n");
    print_cp932("削除実行フォルダ数     : $result->{deleted_count}\n");
    print_cp932("削除失敗数             : $result->{delete_error_count}\n");
    print_cp932("サブフォルダskip数     : $result->{skipped_subdir_dirs}\n");
    print_cp932("除外skipグループ数     : $result->{skipped_exclude_groups}\n");
    print_cp932("ハッシュ失敗数         : $result->{hash_error_count}\n");
    print_cp932("削除予定サイズ合計     : $result->{delete_size_planned} bytes\n");
    print_cp932("実削除サイズ合計       : $result->{delete_size_done} bytes\n");
    print_cp932("削除失敗サイズ合計     : $result->{delete_size_failed} bytes\n");
}

sub log_file_summary {
    my ($log_fh, $label, $result) = @_;

    return unless $log_fh;

    log_utf8($log_fh, "$label: 対象=$result->{total_files} / 重複組=$result->{duplicate_groups} / 削除候補=$result->{delete_candidates} / 削除成功=$result->{deleted_count} / 削除失敗=$result->{delete_error_count} / HASH失敗=$result->{hash_error_count} / 削除予定サイズ=$result->{delete_size_planned} bytes / 実削除サイズ=$result->{delete_size_done} bytes / 削除失敗サイズ=$result->{delete_size_failed} bytes\n\n");
}

sub log_folder_summary {
    my ($log_fh, $label, $result) = @_;

    return unless $log_fh;

    log_utf8($log_fh, "$label: 対象フォルダ=$result->{target_dirs} / 対象ファイル=$result->{total_files} / 重複組=$result->{duplicate_groups} / 削除候補フォルダ=$result->{delete_candidates} / 削除成功フォルダ=$result->{deleted_count} / 削除失敗=$result->{delete_error_count} / サブフォルダskip=$result->{skipped_subdir_dirs} / 除外skip=$result->{skipped_exclude_groups} / HASH失敗=$result->{hash_error_count} / 削除予定サイズ=$result->{delete_size_planned} bytes / 実削除サイズ=$result->{delete_size_done} bytes / 削除失敗サイズ=$result->{delete_size_failed} bytes\n\n");
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

    if ($opt->{folder_mode}) {
        return "直下子フォルダ重複比較";
    }

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

sub exclude_rule_label {
    my ($opt) = @_;

    return defined $opt->{exclude_regex_text}
        ? "ファイル名 regex='$opt->{exclude_regex_text}'"
        : "なし";
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
