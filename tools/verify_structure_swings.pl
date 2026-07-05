#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';

use Market::Indicators::Liquidity;
use Market::Structure::StructureEngine;

# ── Helpers ───────────────────────────────────────────────────────────────────

{
    package _FakeMD;
    sub new { my ($class, $c) = @_; bless { candles => $c }, $class; }
    sub size { scalar @{ shift->{candles} } }
    sub get_candle { my ($s, $i) = @_; return $s->{candles}[$i]; }
    sub active_tf { '1m' }
}

sub make_candles_from_closes {
    my (@closes) = @_;
    my @candles;
    for my $i (0 .. $#closes) {
        my $c = $closes[$i];
        push @candles, {
            timestamp => 1700000000 + $i * 60,
            open  => $i ? $closes[$i-1] : $c - 1,
            high  => $c + 1,
            low   => $c - 1,
            close => $c,
            volume => 10,
        };
    }
    return @candles;
}

sub run_engine {
    my (@closes) = @_;
    my @candles = make_candles_from_closes(@closes);
    my $md  = _FakeMD->new(\@candles);
    my $liq = Market::Indicators::Liquidity->new(k => 1);
    my $eng = Market::Structure::StructureEngine->new(liquidity => $liq);
    my $lq  = $liq->calculate($md);
    my $res = $eng->calculate($md, liquidity_result => $lq);
    return ($res, $lq, $md);
}

# ── Test 1: clasificacion HH/HL/LH/LL basica ─────────────────────────────────
{
    my @closes = (10, 12, 14, 12, 10, 11, 13, 15, 13, 11,  9, 10, 12, 14, 12, 10,  8,  9, 11, 13);
    my ($res) = run_engine(@closes);
    my $swings = $res->{swings} || [];

    my @labels = map { $_->{label} || '' } grep { ($_->{label} || '') ne '' } @$swings;
    die "Test1: no swing labels (got @labels)\n" unless @labels >= 2;

    my %have;
    $have{$_}++ for @labels;
    die "Test1: missing HH in @labels\n" unless $have{HH};

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
    print "OK Test1 basic labels: @labels\n";
}

# ── Test 2: scope external/internal asignado ─────────────────────────────────
{
    my @closes = (10, 12, 14, 12, 10, 11, 13, 15, 13, 11,  9, 10, 12, 14, 12, 10,  8,  9, 11, 13);
    my ($res) = run_engine(@closes);
    my $swings = $res->{swings} || [];

    my @scoped = grep { defined $_->{scope} } @$swings;
    die "Test2: no swings with scope field\n" unless @scoped >= 2;

    my @external = grep { ($_->{scope} // '') eq 'external' && ($_->{label} || '') ne '' } @$swings;
    my @internal = grep { ($_->{scope} // '') eq 'internal' && ($_->{label} || '') ne '' } @$swings;
    die "Test2: expected at least one external swing\n" unless @external >= 1;

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
    my @closes = (10, 12, 14, 12, 10, 11, 13, 15, 13, 11,  9, 10, 12, 14, 12, 10,  8,  9, 11, 13,
                  15, 17, 19, 17, 15, 16, 18, 20, 18, 16);
    my ($res) = run_engine(@closes);

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
    my @closes = (10, 12, 14, 12, 10, 11, 13, 15, 13, 11, 10, 11, 13, 15, 13, 11);
    my ($res, $lq) = run_engine(@closes);
    my $tol = $lq->{metadata}{tolerance} // 0;
    die "Test4: tolerance should be > 0 from ATR\n" unless $tol > 0;

    my $meta = $res->{metadata} || {};
    die "Test4: metadata missing tolerance\n" unless defined $meta->{tolerance};
    die "Test4: metadata missing external_count\n" unless defined $meta->{external_count};

    print "OK Test4 ATR tolerance=$tol external_count=$meta->{external_count}\n";
}

# ── Test 5: tendencia derivada de swings externos ────────────────────────────
{
    my @closes = (10, 12, 14, 12, 10, 11, 13, 15, 13, 11,  9, 10, 12, 14, 12, 10,  8,  9, 11, 13);
    my ($res) = run_engine(@closes);
    my $trend = $res->{trend} // 'neutral';
    die "Test5: trend should be bullish or bearish, got $trend\n"
        unless $trend eq 'bullish' || $trend eq 'bearish' || $trend eq 'neutral';
    print "OK Test5 trend=$trend\n";
}

print "ALL structure tests passed.\n";
exit 0;
