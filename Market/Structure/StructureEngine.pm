package Market::Structure::StructureEngine;

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../..";

use Market::Indicators::Liquidity;
use Market::Structure::BOSDetector;
use Market::Structure::CHOCHDetector;

sub new {
    my ($class, %args) = @_;
    my $self = {
        liquidity => $args{liquidity} || Market::Indicators::Liquidity->new(),
        bos_detector => $args{bos_detector} || Market::Structure::BOSDetector->new(),
        choch_detector => $args{choch_detector} || Market::Structure::CHOCHDetector->new(),
        swings => [],
        trend => 'neutral',
        breaks => [],
        changes => [],
        metadata => {},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{swings} = [];
    $self->{trend} = 'neutral';
    $self->{breaks} = [];
    $self->{changes} = [];
    $self->{metadata} = {};
    $self->{liquidity}->reset() if $self->{liquidity} && $self->{liquidity}->can('reset');
    $self->{bos_detector}->reset() if $self->{bos_detector} && $self->{bos_detector}->can('reset');
    $self->{choch_detector}->reset() if $self->{choch_detector} && $self->{choch_detector}->can('reset');
    return $self;
}

sub calculate {
    my ($self, $market_data, %args) = @_;
    return {} unless $market_data;

    my $replay_controller = $args{replay_controller};
    my $liquidity_result  = $args{liquidity_result};
    if (!$liquidity_result || ref $liquidity_result ne 'HASH') {
        $liquidity_result = $self->{liquidity}->calculate($market_data, %args);
    }
    my $total = $market_data->size();
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;
    my $last_index = (defined $visible_limit && $visible_limit >= 0 && $visible_limit < $total)
        ? $visible_limit : ($total - 1);

    my $candles = [];
    for (my $i = 0; $i <= $last_index; $i++) {
        my $c = $market_data->get_candle($i);
        push @$candles, $c if $c;
    }

    my $tol = 1e-6;
    if ($liquidity_result->{metadata} && defined $liquidity_result->{metadata}{tolerance}) {
        $tol = $liquidity_result->{metadata}{tolerance};
    }

    my $source_swings = $liquidity_result->{swings} || [];
    my $swings = [];
    for my $swing (@$source_swings) {
        next if defined $visible_limit && $swing->{index} > $visible_limit;
        my $st = $swing->{type} || '';
        my $class = $self->_classify_swing($swings, $swing, $tol);
        push @$swings, {
            index       => $swing->{index},
            price       => $swing->{price},
            previous    => $swing->{previous},
            source_type => $st,
            kind        => ($st eq 'swing_high' ? 'high' : 'low'),
            type        => $class,
            label       => $self->_swing_label($class),
        };
    }

    $self->_assign_swing_scopes($swings);
    $self->_reclassify_vs_external($swings, $tol);
    $self->_assign_swing_scopes($swings);

    $self->{swings} = $swings;
    $self->{trend}  = $self->_derive_trend($swings);

    my $break_seq = $self->_scan_structure_breaks($swings, $candles, $last_index);
    $self->{breaks}  = $self->{bos_detector}->detect($break_seq);
    $self->{changes} = $self->{choch_detector}->detect($break_seq);

    $self->{metadata} = {
        timeframe       => $args{timeframe} || $market_data->active_tf(),
        swing_count     => scalar(@$swings),
        external_count  => scalar(grep { ($_->{scope} // '') eq 'external' } @$swings),
        visible_limit   => $visible_limit,
        bos_count       => scalar(@{ $self->{breaks} }),
        choch_count     => scalar(@{ $self->{changes} }),
        tolerance       => $tol,
        show_internal   => 0,
    };

    return {
        swings   => $self->{swings},
        trend    => $self->{trend},
        breaks   => $self->{breaks},
        changes  => $self->{changes},
        metadata => $self->{metadata},
    };
}

# _scan_structure_breaks($swings, $candles, $last_index) -> \@events
# Solo swings con scope=external definen niveles de referencia para BOS/CHoCH.
sub _scan_structure_breaks {
    my ($self, $swings, $candles, $last_index) = @_;
    my @events;
    return \@events unless $swings && @$swings && $candles && @$candles;

    my @sorted = sort { $a->{index} <=> $b->{index} }
        grep { ($_->{scope} // 'external') eq 'external' } @$swings;
    return \@events unless @sorted;

    my $si = 0;
    my ($rh, $rhi, $rl, $rli);
    my $trend = 0;
    my $id = 0;

    for (my $i = 0; $i <= $last_index; $i++) {
        while ($si <= $#sorted && $sorted[$si]{index} <= $i) {
            my $s = $sorted[$si];
            if ($s->{kind} eq 'high') { $rh = $s->{price}; $rhi = $s->{index}; }
            else                      { $rl = $s->{price}; $rli = $s->{index}; }
            $si++;
        }
        my $c = $candles->[$i];
        next unless $c;
        my $close = $c->{close};
        next unless defined $close;

        if (defined $rh && defined $rhi && $rhi < $i && $close > $rh) {
            my $kind = ($trend < 0) ? 'CHoCH' : 'BOS';
            push @events, {
                event_id     => ++$id,
                kind         => $kind,
                direction    => 'bullish',
                trend_before => $trend,
                level        => $rh,
                index        => $i,
                swing_index  => $rhi,
                scope        => 'external',
            };
            $trend = 1;
            $rh = undef; $rhi = undef;
        }
        elsif (defined $rl && defined $rli && $rli < $i && $close < $rl) {
            my $kind = ($trend > 0) ? 'CHoCH' : 'BOS';
            push @events, {
                event_id     => ++$id,
                kind         => $kind,
                direction    => 'bearish',
                trend_before => $trend,
                level        => $rl,
                index        => $i,
                swing_index  => $rli,
                scope        => 'external',
            };
            $trend = -1;
            $rl = undef; $rli = undef;
        }
    }
    return \@events;
}

sub structure { my ($self) = @_; return { swings => $self->{swings}, trend => $self->{trend}, breaks => $self->{breaks}, changes => $self->{changes}, metadata => $self->{metadata} }; }
sub events { my ($self) = @_; return [ @{ $self->{breaks} }, @{ $self->{changes} } ]; }

sub _classify_swing {
    my ($self, $current, $swing, $tol) = @_;
    $tol //= 1e-6;
    my $source_type = $swing->{type} || '';
    return 'swing' unless $source_type eq 'swing_high' || $source_type eq 'swing_low';

    my $prev_same;
    for my $s (reverse @$current) {
        next unless ($s->{source_type} || '') eq $source_type;
        $prev_same = $s;
        last;
    }
    return 'swing' unless $prev_same;

    return $self->_compare_prices($source_type, $prev_same->{price}, $swing->{price}, $tol);
}

sub _reclassify_vs_external {
    my ($self, $swings, $tol) = @_;
    $tol //= 1e-6;
    return unless $swings && @$swings;

    my ($last_ext_high, $last_ext_low);
    my @sorted = sort { $a->{index} <=> $b->{index} } @$swings;

    for my $s (@sorted) {
        my $st = $s->{source_type} || '';
        next unless $st eq 'swing_high' || $st eq 'swing_low';

        if ($st eq 'swing_high') {
            if (defined $last_ext_high) {
                my $class = $self->_compare_prices('swing_high', $last_ext_high, $s->{price}, $tol);
                $s->{type}  = $class;
                $s->{label} = $self->_swing_label($class);
            }
            $last_ext_high = $s->{price}
                if ($s->{scope} // '') eq 'external';
        }
        else {
            if (defined $last_ext_low) {
                my $class = $self->_compare_prices('swing_low', $last_ext_low, $s->{price}, $tol);
                $s->{type}  = $class;
                $s->{label} = $self->_swing_label($class);
            }
            $last_ext_low = $s->{price}
                if ($s->{scope} // '') eq 'external';
        }
    }
}

sub _compare_prices {
    my ($self, $source_type, $prev_price, $curr_price, $tol) = @_;
    $tol //= 1e-6;

    if ($source_type eq 'swing_high') {
        return 'Higher High' if $curr_price > $prev_price + $tol;
        return 'Lower High'  if $curr_price < $prev_price - $tol;
        return 'Equal High';
    }
    return 'Higher Low' if $curr_price > $prev_price + $tol;
    return 'Lower Low'  if $curr_price < $prev_price - $tol;
    return 'Equal Low';
}

# _assign_swing_scopes($swings)
# Leg alcista: HH/HL externos; LH/LL internos. Leg bajista: inverso.
sub _assign_swing_scopes {
    my ($self, $swings) = @_;
    return unless $swings && @$swings;

    my $leg     = 0;
    my $leg_id  = 0;
    my @labeled = sort { $a->{index} <=> $b->{index} }
        grep { ($_->{label} || '') ne '' } @$swings;

    for my $s (@labeled) {
        my $lbl  = $s->{label};
        my $kind = $s->{kind} // '';

        if ($leg == 0) {
            $s->{scope}  = 'external';
            $s->{leg_id} = $leg_id;
            $leg = 1  if $lbl =~ /^(HH|HL)$/ || ($lbl eq 'EQH' && $kind eq 'high');
            $leg = -1 if $lbl =~ /^(LL|LH)$/ || ($lbl eq 'EQL' && $kind eq 'low');
            next;
        }

        if ($leg > 0) {
            if ($lbl =~ /^(HH|HL)$/ || ($lbl eq 'EQH' && $kind eq 'high')
                || ($lbl eq 'EQL' && $kind eq 'low'))
            {
                $s->{scope} = 'external';
            }
            else {
                $s->{scope} = 'internal';
            }
            if ($lbl eq 'LL') {
                $leg = -1;
                $leg_id++;
            }
        }
        else {
            if ($lbl =~ /^(LL|LH)$/ || ($lbl eq 'EQL' && $kind eq 'low')
                || ($lbl eq 'EQH' && $kind eq 'high'))
            {
                $s->{scope} = 'external';
            }
            else {
                $s->{scope} = 'internal';
            }
            if ($lbl eq 'HH') {
                $leg = 1;
                $leg_id++;
            }
        }
        $s->{leg_id} = $leg_id;
    }

    for my $s (@$swings) {
        $s->{scope}  //= 'internal';
        $s->{leg_id} //= $leg_id;
    }
}

sub _swing_label {
    my ($self, $type) = @_;
    return '' unless defined $type;
    return 'HH'  if $type eq 'Higher High';
    return 'HL'  if $type eq 'Higher Low';
    return 'LH'  if $type eq 'Lower High';
    return 'LL'  if $type eq 'Lower Low';
    return 'EQH' if $type eq 'Equal High';
    return 'EQL' if $type eq 'Equal Low';
    return '';
}

sub _derive_trend {
    my ($self, $swings) = @_;
    return 'neutral' unless $swings && @$swings;

    my @external = grep {
        ($_->{scope} // '') eq 'external' && (($_->{label} || '') ne '')
    } @$swings;
    return 'neutral' unless @external;

    my ($bull, $bear) = (0, 0);
    my $from = @external > 4 ? @external - 4 : 0;
    for my $s (@external[$from .. $#external]) {
        my $lbl = $s->{label} || '';
        $bull++ if $lbl =~ /^(HH|HL)$/ || $lbl eq 'EQH';
        $bear++ if $lbl =~ /^(LL|LH)$/ || $lbl eq 'EQL';
    }
    return 'bullish' if $bull > $bear;
    return 'bearish' if $bear > $bull;

    my $last_lbl = $external[-1]{label} || '';
    return 'bullish' if $last_lbl =~ /^(HH|HL)$/;
    return 'bearish' if $last_lbl =~ /^(LL|LH)$/;
    return 'neutral';
}

1;
