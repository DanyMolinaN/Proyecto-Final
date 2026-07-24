package Market::Concepts::FVGEngine;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        gaps => [],
        active => [],
        metadata => {},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{gaps} = [];
    $self->{active} = [];
    $self->{metadata} = {};
    return $self;
}

sub calculate {
    my ($self, $market_data, $structure_engine, %args) = @_;
    return {} unless $market_data;

    $self->reset();
    my $total = $market_data->size();
    my $replay_controller = $args{replay_controller};
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;
    # Ultimo indice analizable: respeta el puntero de Replay (no mira el futuro).
    my $last_index = (defined $visible_limit && $visible_limit >= 0 && $visible_limit < $total)
        ? $visible_limit : ($total - 1);

    # Horizonte de desvanecimiento (en velas). Pasado este lapso la FVG se
    # considera completamente desvanecida y deja de dibujarse.
    my $max_age = $args{max_age_bars} || $self->{max_age_bars} || 50;

    my $candles = [];
    for (my $i = 0; $i <= $last_index; $i++) {
        my $c = $market_data->get_candle($i);
        push @$candles, $c if $c;
    }

    my $gaps = [];
    my $min_index = 2;
    if (defined $args{view_start}) {
        my $buf = ($args{max_age_bars} || $self->{max_age_bars} || 50) * 4;
        $min_index = $args{view_start} - $buf;
        $min_index = 2 if $min_index < 2;
    }

    for (my $i = 2; $i <= $#$candles; $i++) {
        next if $i < $min_index;
        my $c1 = $candles->[$i - 2];
        my $c2 = $candles->[$i - 1];
        my $c3 = $candles->[$i];
        next unless $c1 && $c2 && $c3;

        my $bullish = $c3->{low}  > $c1->{high};
        my $bearish = $c3->{high} < $c1->{low};
        next unless $bullish || $bearish;

        # Edad = velas transcurridas desde la creacion hasta la ultima analizable.
        my $age = $last_index - $i;

        # Limites de precio de la zona (p_lo inferior, p_hi superior).
        my ($p_lo, $p_hi);
        if ($bullish) { $p_lo = $c1->{high}; $p_hi = $c3->{low}; }
        else          { $p_lo = $c3->{high}; $p_hi = $c1->{low}; }

        # Mitigacion: ¿alguna vela posterior reentra en la zona? (dentro del
        # horizonte). Bullish -> el precio baja al techo inferior; bearish ->
        # el precio sube al piso superior.
        my $filled_index;
        my $scan_end = $i + $max_age;
        $scan_end = $#$candles if $scan_end > $#$candles;
        for (my $j = $i + 1; $j <= $scan_end; $j++) {
            my $cj = $candles->[$j];
            next unless $cj;
            if ($bullish) { if ($cj->{low}  <= $p_lo) { $filled_index = $j; last; } }
            else          { if ($cj->{high} >= $p_hi) { $filled_index = $j; last; } }
        }
        my $filled = defined $filled_index ? 1 : 0;

        my $touched_index;
        my $state = 'Detected';
        if ($filled) {
            $state = 'Mitigated';
        }
        else {
            for (my $j = $i + 1; $j <= $scan_end; $j++) {
                my $cj = $candles->[$j];
                next unless $cj;
                my $touched = $bullish
                    ? ($cj->{low} <= $p_hi)
                    : ($cj->{high} >= $p_lo);
                if ($touched) {
                    $touched_index = $j;
                    $state = 'Touched';
                    last;
                }
            }
        }

        # Fuerza se calcula en el overlay segun el viewport actual (permite pan
        # sin invalidar cache). Aqui solo marcamos mitigacion.
        my $strength = 1;
        $strength = 0.35 if $filled;

        push @$gaps, {
            type          => $bullish ? 'bullish' : 'bearish',
            top           => $p_hi,
            bottom        => $p_lo,
            price         => ($p_hi + $p_lo) / 2,
            mid_price     => ($p_hi + $p_lo) / 2,
            size          => abs($p_hi - $p_lo),
            index         => $i,
            created_index => $i,
            extend_to     => ($filled ? $filled_index : $last_index),
            age           => $age,
            strength      => $strength,
            filled        => $filled,
            filled_index  => $filled_index,
            touched_index => $touched_index,
            state         => $state,
        };
    }

    $self->{gaps}   = $gaps;
    $self->{active} = [ grep { !$_->{filled} } @$gaps ];
    $self->{metadata} = {
        timeframe     => $args{timeframe} || $market_data->active_tf(),
        gap_count     => scalar(@$gaps),
        active_count  => scalar(@{ $self->{active} }),
        visible_limit => $visible_limit,
        max_age_bars  => $max_age,
    };

    return {
        gaps     => $self->{gaps},
        active   => $self->{active},
        metadata => $self->{metadata},
    };
}

sub gaps { my ($self) = @_; return $self->{gaps} || []; }
sub active { my ($self) = @_; return $self->{active} || []; }

1;
