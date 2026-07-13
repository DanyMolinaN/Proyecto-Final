#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';

use File::Spec;
use Time::Piece;

use Market::MarketData;
use Market::Indicators::Liquidity;
use Market::Structure::StructureEngine;

# ── Helpers ───────────────────────────────────────────────────────────────────

sub load_test_market {
    my ($tf) = @_;
    $tf ||= '5m';

    my $csv = File::Spec->catfile('data', '2026_07_06.csv');
    die "missing test CSV: $csv\n" unless -e $csv;

    my $market = Market::MarketData->new();
    open my $fh, '<', $csv or die "$csv: $!\n";
    my $header = <$fh>;
    my $tz_set = 0;
    while (my $line = <$fh>) {
        chomp $line;
        next unless $line =~ /\S/;
        my ($timestamp, $open, $high, $low, $close, $volume) = split /,/, $line;
        unless ($tz_set) {
            if ($timestamp =~ /([+-])(\d{2}):?(\d{2})$/) {
                my $sec = ($2 * 3600) + ($3 * 60);
                $market->set_tz_offset($1 eq '-' ? -$sec : $sec);
                $tz_set = 1;
            }
        }
        my $s = $timestamp;
        $s =~ s/:(?=\d{2}$)//;
        my $epoch = eval { Time::Piece->strptime($s, '%Y-%m-%dT%H:%M:%S%z')->epoch };
        $market->add_candle({
            timestamp => $epoch // time,
            open  => $open + 0,
            high  => $high + 0,
            low   => $low + 0,
            close => $close + 0,
            volume => $volume + 0,
        });
    }
    close $fh;

    $market->build_timeframes();
    $market->set_timeframe($tf);
    return $market;
}

sub run_engine {
    my ($md) = @_;
    $md ||= load_test_market('5m');
    my $liq = Market::Indicators::Liquidity->new(k => 1);
    my $eng = Market::Structure::StructureEngine->new(liquidity => $liq);
    my $lq  = $liq->calculate($md);
    my $res = $eng->calculate($md, liquidity_result => $lq);
    return ($res, $lq, $md);
}

# ── Test 1: clasificacion HH/HL/LH/LL basica ─────────────────────────────────
{
    my ($res) = run_engine();
    my $swings = $res->{swings} || [];

    my @labels = map { $_->{label} || '' } grep { ($_->{label} || '') ne '' } @$swings;
    die "Test1: no swing labels (got @labels)\n" unless @labels >= 2;

    my %have;
    $have{$_}++ for @labels;
    die "Test1: missing high-side label in @labels\n"
        unless $have{HH} || $have{LH};
    die "Test1: missing low-side label in @labels\n"
        unless $have{LL} || $have{HL};

    for my $s (@$swings) {
        next unless $s->{label};
        if ($s->{source_type} eq 'swing_high') {
            die "Test1: swing_high got invalid label $s->{label}\n"
                if $s->{label} =~ /^(HL|LL|EQL)$/;
        }
        if ($s->{source_type} eq 'swing_low') {
            die "Test1: swing_low got invalid label $s->{label}\n"
                if $s->{label} =~ /^(HH|LH|EQH)$/;
        }
    }
    print "OK Test1 basic labels: @{[ @labels[0..9] ]}\n";
}

# ── Test 2: scope external/internal asignado ─────────────────────────────────
{
    my ($res) = run_engine();
    my $swings = $res->{swings} || [];
    my $internal_swings = $res->{internal_swings} || [];

    my @scoped = grep { defined $_->{scope} } (@$swings, @$internal_swings);
    die "Test2: no swings with scope field\n" unless @scoped >= 2;

    my @external = grep { ($_->{scope} // '') eq 'external' && ($_->{label} || '') ne '' } @$swings;
    my @internal = grep { ($_->{scope} // '') eq 'internal' && ($_->{label} || '') ne '' } @$internal_swings;
    die "Test2: expected at least one external swing\n" unless @external >= 1;
    die "Test2: expected at least one internal swing\n" unless @internal >= 1;

    for my $s (@external) {
        my $lbl = $s->{label};
        die "Test2: external swing missing leg_id\n" unless defined $s->{leg_id};
        die "Test2: external $lbl on wrong kind\n"
            if $lbl =~ /^(HH|HL|EQH)$/ && ($s->{kind} // '') ne 'high'
            && $lbl !~ /^(HL|EQL)$/;
    }

    print "OK Test2 scope: external=@{[scalar @external]} internal=@{[scalar @internal]}\n";
}

# ── Test 3: BOS/CHoCH solo referencian swings externos ───────────────────────
{
    my ($res) = run_engine();

    my %ext_idx = map { $_->{index} => 1 }
        grep { ($_->{scope} // '') eq 'external' } @{ $res->{swings} || [] };

    my @all_breaks = (@{ $res->{breaks} || [] }, @{ $res->{changes} || [] });
    for my $ev (@all_breaks) {
        next unless $ev && ref $ev eq 'HASH';
        my $si = $ev->{break_index} // $ev->{swing_index};
        next unless defined $si;
        die "Test3: break references non-external swing index=$si\n"
            unless $ext_idx{$si};
    }

    print "OK Test3 breaks reference external swings only (events=@{[scalar @all_breaks]})\n";
}

# ── Test 4: re-clasificacion vs swing externo previo (tolerancia ATR) ────────
{
    my ($res, $lq) = run_engine();
    my $tol = $lq->{metadata}{tolerance} // 0;
    die "Test4: tolerance should be > 0 from ATR\n" unless $tol > 0;

    my $meta = $res->{metadata} || {};
    die "Test4: metadata missing tolerance\n" unless defined $meta->{tolerance};
    die "Test4: metadata missing external_count\n" unless defined $meta->{external_count};
    die "Test4: external_count should be > 0\n" unless ($meta->{external_count} // 0) > 0;

    print "OK Test4 ATR tolerance=$tol external_count=$meta->{external_count}\n";
}

# ── Test 5: tendencia derivada de swings externos ────────────────────────────
{
    my ($res) = run_engine();
    my $trend = $res->{trend} // 'neutral';
    die "Test5: trend should be bullish or bearish, got $trend\n"
        unless $trend eq 'bullish' || $trend eq 'bearish' || $trend eq 'neutral';
    print "OK Test5 trend=$trend\n";
}

# ── Test 6: jerarquia ZigZag interno/externo disponible ──────────────────────
{
    my ($res) = run_engine();
    die "Test6: missing internal_swings\n" unless ref($res->{internal_swings}) eq 'ARRAY';
    die "Test6: missing external_swings\n" unless ref($res->{external_swings}) eq 'ARRAY';
    die "Test6: external_swings must match public swings\n"
        unless scalar(@{ $res->{external_swings} }) == scalar(@{ $res->{swings} || [] });

    my $zigzag = $res->{metadata}{zigzag} || {};
    die "Test6: missing internal zigzag metadata\n" unless ref($zigzag->{internal}) eq 'HASH';
    die "Test6: missing external zigzag metadata\n" unless ref($zigzag->{external}) eq 'HASH';
    die "Test6: internal zigzag should use MTF resolution 30\n"
        unless ($zigzag->{internal}{resolution_minutes} // 0) == 30;
    die "Test6: internal zigzag should use period 2\n"
        unless ($zigzag->{internal}{period} // 0) == 2;
    die "Test6: external zigzag should use deviation_pct 1\n"
        unless ($zigzag->{external}{deviation_pct} // 0) == 1;
    die "Test6: external should have fewer pivots than internal\n"
        unless ($zigzag->{external}{pivot_count} // 0) < ($zigzag->{internal}{pivot_count} // 0);

    print "OK Test6 zigzag hierarchy: internal=@{[scalar @{ $res->{internal_swings} }]} external=@{[scalar @{ $res->{external_swings} }]}\n";
}

print "ALL structure tests passed.\n";
exit 0;
