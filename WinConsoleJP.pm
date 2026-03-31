package WinConsoleJP;

use strict;
use warnings;
use utf8;

use Encode qw(decode encode FB_CROAK);
use Exporter ();

our @ISA = qw(Exporter);

our @EXPORT = qw(console_init disp print_cp932 warn_cp932);
our @EXPORT_OK = qw(console_init disp print_cp932 warn_cp932 set_display_mode);

our %EXPORT_TAGS = (
    default => [qw(console_init disp print_cp932 warn_cp932)],
    rough   => [],
    exact   => [],
);

my $DISPLAY_MODE = 'rough';

sub import {
    my ($class, @args) = @_;

    my @exports;
    my $mode;

    for my $arg (@args) {
        if ($arg eq ':rough') {
            $mode = 'rough';
        }
        elsif ($arg eq ':exact') {
            $mode = 'exact';
        }
        elsif ($arg eq ':default') {
            push @exports, @{ $EXPORT_TAGS{default} };
        }
        else {
            push @exports, $arg;
        }
    }

    $DISPLAY_MODE = $mode if defined $mode;
    @exports = @EXPORT unless @exports;

    $class->export_to_level(1, $class, @exports);
}

sub console_init {
    if (_is_windows()) {
        binmode STDOUT, ':encoding(cp932)';
        binmode STDERR, ':encoding(cp932)';
    }
    else {
        binmode STDOUT, ':encoding(UTF-8)';
        binmode STDERR, ':encoding(UTF-8)';
    }
}

sub set_display_mode {
    my ($mode) = @_;
    die "display mode must be rough or exact\n"
        unless defined $mode && ($mode eq 'rough' || $mode eq 'exact');
    $DISPLAY_MODE = $mode;
}

sub disp {
    my ($s) = @_;
    return '' unless defined $s;

    my $text = _to_perl_text($s);
    return $text unless _is_windows();

    return _to_cp932_safe_text($text, $DISPLAY_MODE);
}

sub print_cp932 {
    my ($text) = @_;
    $text = '' unless defined $text;
    print disp($text);
}

sub warn_cp932 {
    my ($text) = @_;
    $text = '' unless defined $text;
    print STDERR disp($text);
}

sub _to_perl_text {
    my ($s) = @_;
    return $s if utf8::is_utf8($s);

    return eval { decode('cp932', $s, 1) } // $s;
}

sub _to_cp932_safe_text {
    my ($text, $mode) = @_;

    my $out = '';

    for my $ch (split //, $text) {
        if (_encodable_cp932($ch)) {
            $out .= $ch;
        }
        else {
            $out .= ($mode eq 'exact')
                ? sprintf('\\x{%04X}', ord($ch))
                : '×';
        }
    }

    return $out;
}

sub _encodable_cp932 {
    my ($ch) = @_;

    return eval {
        encode('cp932', $ch, FB_CROAK);
        1;
    } ? 1 : 0;
}

sub _is_windows {
    return $^O eq 'MSWin32';
}

1;
