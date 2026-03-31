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
    $IS_WINDOWS  = ($^O eq 'MSWin32') ? 1 : 0;
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
    my ($do_delete, $target_dir) = parse_args(@ARGV);

    my $log_file = make_log_filename();

    print_cp932("モード       : " . ($do_delete ? "実削除" : "dry-run") . "\n");
    print_cp932("対象フォルダ : $target_dir\n");
    print_cp932("OS判定       : " . ($IS_WINDOWS ? "Windows" : "非Windows") . "\n");
    if ($IS_WINDOWS) {
        print_cp932("列挙方式     : " . ($USE_LONGPATH ? "Win32::LongPath" : "標準") . "\n");
    }
    if ($do_delete) {
        print_cp932("ログファイル : $log_file\n");
    }
    print_cp932("\n");

    my $result = process_duplicates($target_dir, $log_file, $do_delete);

    print_cp932("\n");
    print_cp932("===== 実行結果 =====\n");
    print_cp932("対象ファイル数     : $result->{total_files}\n");
    print_cp932("重複グループ数     : $result->{duplicate_groups}\n");
    print_cp932("削除候補数         : $result->{delete_candidates}\n");
    print_cp932("削除実行数         : $result->{deleted_count}\n");
    print_cp932("削除失敗数         : $result->{delete_error_count}\n");
    print_cp932("ハッシュ失敗数     : $result->{hash_error_count}\n");

    if (!$do_delete) {
        print_cp932("\n");
        print_cp932("※ dry-run です。実際には削除していません。\n");
        print_cp932("  実際に削除するには --delete を付けて実行してください。\n");
    }
}

sub parse_args {
    my @args = @_;

    my $do_delete = 0;
    my $target_dir;

    for my $arg (@args) {
        if ($arg eq '--delete') {
            $do_delete = 1;
        }
        elsif (!defined $target_dir) {
            $target_dir = $arg;
        }
        else {
            die usage();
        }
    }

    die usage() unless defined $target_dir;

    my $exists = ($IS_WINDOWS && $USE_LONGPATH)
        ? testL('d', $target_dir)
        : -d $target_dir;

    die "エラー: フォルダが見つかりません: $target_dir\n" unless $exists;

    return ($do_delete, $target_dir);
}

sub usage {
    return <<"USAGE";
使い方:
  perl dupdel.pl 対象フォルダ
  perl dupdel.pl --delete 対象フォルダ

説明:
  --delete を付けない場合は dry-run です（削除しません）。
  指定フォルダ直下の通常ファイルのみを対象に、重複ファイルを検出します。
  サブフォルダ内のファイルは処理しません。
USAGE
}

sub process_duplicates {
    my ($dir, $log_file, $do_delete) = @_;

    my %result = (
        total_files         => 0,
        duplicate_groups    => 0,
        delete_candidates   => 0,
        deleted_count       => 0,
        delete_error_count  => 0,
        hash_error_count    => 0,
    );

    my @files = collect_files($dir);
    $result{total_files} = scalar @files;

    my $log_fh;
    if ($do_delete) {
        my $needs_separator = (-e $log_file && -s $log_file) ? 1 : 0;

        open $log_fh, '>>:encoding(UTF-8)', $log_file
            or die "ログファイルを開けません: $log_file\n";

        log_utf8($log_fh, "\n") if $needs_separator;
        log_utf8($log_fh, "===== " . timestamp_for_log() . " START =====\n");
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
                $result{hash_error_count}++;
                print_cp932("HASH失敗: $f->{name}\n");
                if ($do_delete) {
                    log_utf8($log_fh, "HASH失敗: $f->{name}\n");
                }
                next;
            }
            push @{ $by_sha1{$sha1} }, $f;
        }

        for my $sha1 (sort keys %by_sha1) {
            my $dups = $by_sha1{$sha1};
            next if @$dups < 2;

            my @sorted = sort { $a->{name} cmp $b->{name} } @$dups;
            my $keep = shift @sorted;

            push @dup_groups, {
                keep => $keep,
                dels => [ @sorted ],
            };
        }
    }

    @dup_groups = sort { $a->{keep}{name} cmp $b->{keep}{name} } @dup_groups;

    for my $group (@dup_groups) {
        my $keep = $group->{keep};
        my @sorted = @{ $group->{dels} };

        $result{duplicate_groups}++;
        $result{delete_candidates} += scalar @sorted;

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
                    $result{deleted_count}++;
                    log_utf8($log_fh, "-> $del->{name}\n");
                }
                else {
                    $result{delete_error_count}++;
                    warn_cp932("削除失敗: $del->{name} : $!\n");
                    log_utf8($log_fh, "-> $del->{name} [削除失敗: $!]\n");
                }
            }

            log_utf8($log_fh, "\n");
        }
    }

    if ($do_delete) {
        log_utf8($log_fh, "\n");
        log_utf8($log_fh, "件数: 対象=$result{total_files} / 重複組=$result{duplicate_groups} / 削除候補=$result{delete_candidates} / 削除成功=$result{deleted_count} / 削除失敗=$result{delete_error_count} / HASH失敗=$result{hash_error_count}\n");
        log_utf8($log_fh, "===== " . timestamp_for_log() . " END =====\n");
        close $log_fh;
    }

    return \%result;
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

    for my $name ($dh->readdirL()) {
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
    return @files;
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
