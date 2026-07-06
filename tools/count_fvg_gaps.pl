#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';

use Time::Piece;

use Market::MarketData;
use Market::Concepts::FVGEngine;
use Market::Structure::StructureEngine;
use Market::Indicators::Liquidity;

my $md = Market::MarketData->new();
load_csv($md, 'data/2026_03.csv');
$md->set_timeframe('1m');
my $total = $md->size();
print "total=$total\n";

my $liq    = Market::Indicators::Liquidity->new();
my $struct = Market::Structure::StructureEngine->new(liquidity => $liq);
my $fvg    = Market::Concepts::FVGEngine->new();
$liq->calculate($md);

my $view_start = $total - 250;
my $view_end   = $total - 1;

my $res = $fvg->calculate($md, $struct);
my $gaps = $res->{gaps} || [];
print "gaps default engine=" . scalar(@$gaps) . "\n";

my $in_view = 0;
my $visible_strength = 0;
for my $g (@$gaps) {
    my $ci = $g->{created_index} // -1;
    next unless $ci >= $view_start && $ci <= $view_end;
    $in_view++;
    $visible_strength++ if ($g->{strength} // 0) > 0.05;
}
print "gaps in last 250 bars=$in_view (strength>0.05: $visible_strength)\n";

exit 0;

sub load_csv {
    my ($market_data, $path) = @_;
    open my $fh, '<', $path or die "No se pudo abrir CSV '$path': $!\n";
    my $header = <$fh>;
    my $tz_set = 0;
    while (my $line = <$fh>) {
        chomp $line;
        next unless $line =~ /\S/;
        my ($timestamp, $open, $high, $low, $close, $volume) = split /,/, $line;

        unless ($tz_set) {
            my $off = tz_offset_seconds($timestamp);
            if (defined $off) {
                $market_data->set_tz_offset($off);
                $tz_set = 1;
            }
        }

        $market_data->add_candle({
            timestamp => parse_timestamp($timestamp),
            open      => $open + 0,
            high      => $high + 0,
            low       => $low + 0,
            close     => $close + 0,
            volume    => ($volume || 0) + 0,
        });
    }
    close $fh;
    $market_data->build_timeframes();
    return 1;
}

sub tz_offset_seconds {
    my ($t) = @_;
    return undef unless defined $t;
    return 0 if $t =~ /Z$/;
    if ($t =~ /([+-])(\d{2}):?(\d{2})$/) {
        my $sec = ($2 * 3600) + ($3 * 60);
        return $1 eq '-' ? -$sec : $sec;
    }
    return undef;
}

sub parse_timestamp {
    my ($t) = @_;
    return $t + 0 if defined $t && $t =~ /^\d+$/;
    die "Timestamp vacio en CSV\n" unless defined $t && $t =~ /\S/;

    my $s = $t;
    $s =~ s/:(?=\d{2}$)//;

    my $epoch;
    eval {
        my $tp = Time::Piece->strptime($s, '%Y-%m-%dT%H:%M:%S%z');
        $epoch = $tp->epoch;
    };
    if ($@) {
        eval {
            my $tp = Time::Piece->strptime($s, '%Y-%m-%d %H:%M:%S');
            $epoch = $tp->epoch;
        };
    }
    die "Timestamp invalido en CSV: $t\n" unless defined $epoch;
    return $epoch;
}
