package Market::Indicators::ZigZag;

use strict;
use warnings;

# =============================================================================
# Motor ZigZag incremental (estilo LonesomeTheBlue / TradingView):
#   ph = ta.highestbars(high, period) == 0 ? high : na
#   pl = ta.lowestbars(low, period)  == 0 ? low  : na
#   dir := ph && !pl ? 1 : pl && !ph ? -1 : dir
#   dirchanged -> add pivot | else -> update pivot (reemplazar si mas extremo)
#
# Estado persistente: update_at_index() por vela. compute() es wrapper batch.
# =============================================================================

# Motor base highestbars/lowestbars (tests / utilidades).
# Internal: Market::Indicators::ZigZagMTF (30m, period 2).
# External: Market::Indicators::ZigZagVolumeProfile (deviation_pct).
use constant INTERNAL_PIVOT_LENGTH => 5;

sub pivot_length_for {
    my ($profile) = @_;
    return INTERNAL_PIVOT_LENGTH if ($profile || '') eq 'internal';
    return INTERNAL_PIVOT_LENGTH;
}

sub new {
    my ( $class, %args ) = @_;
    my $period = $args{pivot_length} // $args{period} // INTERNAL_PIVOT_LENGTH;
    $period = 2 if $period < 2;
    my $self = {
        period      => $period,
        debug       => $args{debug} // 0,   # 1 = log barra-por-barra a STDERR
        _c          => [],
        _pivots     => [],
        _dir        => 0,
        _prev_dir   => 0,
        _last_index => -1,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_c}          = [];
    $self->{_pivots}     = [];
    $self->{_dir}        = 0;
    $self->{_prev_dir}   = 0;
    $self->{_last_index} = -1;
    return $self;
}

# debug_log($msg) — imprime a STDERR solo si debug=>1
sub _debug_log {
    my ($self, $msg) = @_;
    return unless $self->{debug};
    print STDERR "[ZigZag] $msg\n";
}

sub period       { return $_[0]->{period}; }
sub last_index   { return $_[0]->{_last_index}; }
sub get_pivots   { return [ map { +{%$_} } @{ $_[0]->{_pivots} || [] } ]; }

sub update_at_index {
    my ( $self, $candle, $idx ) = @_;
    return unless $candle && ref $candle eq 'HASH';
    return unless defined $idx && $idx >= 0;

    $self->{_c}[$idx] = $candle;
    $self->_process_bar($idx);
    $self->{_last_index} = $idx;
    return $self;
}

sub sync_to_index {
    my ( $self, $market_data, $target_index ) = @_;
    return $self unless $market_data && $market_data->can('get_candle');
    return $self unless defined $target_index && $target_index >= 0;

    if ( $self->{_last_index} > $target_index ) {
        $self->reset();
    }

    my $from = $self->{_last_index} + 1;
    $from = 0 if $from < 0;

    for my $i ( $from .. $target_index ) {
        my $c = $market_data->get_candle($i);
        next unless $c;
        $self->update_at_index( $c, $i );
    }
    return $self;
}

sub get_tentative_segment {
    my ($self) = @_;
    my $pivots = $self->{_pivots};
    # Si hay menos de 2 pivotes, no hay un segmento tentativo completo
    return undef unless $pivots && @$pivots >= 2;

    # El ultimo pivote es el "vivo" (tentativo), el anterior es el ultimo confirmado
    my $last_confirmed = $pivots->[-2];
    my $live_pivot     = $pivots->[-1];

    return {
        from_index => $last_confirmed->{index},
        to_index   => $live_pivot->{index},
        from_price => $last_confirmed->{price},
        to_price   => $live_pivot->{price},
        dir        => ( $live_pivot->{price} > $last_confirmed->{price} ) ? 'up' : 'down',
    };
}

sub pivots_as_swings {
    my ($self) = @_;
    my $pivots = $self->{_pivots} || [];
    
    # Excluir el ultimo pivote porque esta "vivo" (no confirmado)
    my @confirmed = @$pivots > 1 ? @{$pivots}[0 .. $#$pivots - 1] : ();

    return [
        map {
            +{
                index => $_->{index},
                price => $_->{price},
                kind  => $_->{kind},
                type  => $_->{kind} eq 'H' ? 'swing_high' : 'swing_low',
            }
        } @confirmed
    ];
}

# compute($candles) -> \@pivots  (batch, para tests)
sub compute {
    my ( $candles, %args ) = @_;
    my $period = $args{pivot_length} // $args{period} // INTERNAL_PIVOT_LENGTH;
    my $engine = __PACKAGE__->new( pivot_length => $period );
    return [] unless $candles && ref $candles eq 'ARRAY' && @$candles;

    for my $i ( 0 .. $#$candles ) {
        my $c = $candles->[$i];
        next unless $c;
        $engine->update_at_index( $c, $i );
    }
    return $engine->pivots_as_swings();
}

sub _process_bar {
    my ( $self, $i ) = @_;
    my $c      = $self->{_c}[$i];
    my $period = $self->{period};

    my $ph = _is_highest_bar( $self->{_c}, $i, $period );
    my $pl = _is_lowest_bar(  $self->{_c}, $i, $period );

    # --- Replicar: dir := iff(ph and na(pl), 1, iff(pl and na(ph), -1, dir)) ---
    # Si ph && pl simultáneamente, dir NO cambia (mantiene valor anterior).
    if    ( $ph && !$pl ) { $self->{_dir} = 1;  }
    elsif ( $pl && !$ph ) { $self->{_dir} = -1; }

    # Solo continuamos si al menos una señal existe
    return unless $ph || $pl;

    my $dir = $self->{_dir};
    return unless $dir == 1 || $dir == -1;

    # -----------------------------------------------------------------------
    # BUG FIX (vs PineScript): Pine pasa `ph` (o `pl`) a update_zigzag.
    # Si ph==na (false) pero la barra tiene pl, y dir==1, Pine llama:
    #   update_zigzag(zz, ph, bar_index, dir)  con ph = na -> no-op.
    # En Perl, debemos reproducir ese comportamiento:
    #   dir==1  -> solo actúa si la barra ES un pivot high (ph==true)
    #   dir==-1 -> solo actúa si la barra ES un pivot low  (pl==true)
    # Si la barra tiene la señal opuesta a dir, se ignora.
    # -----------------------------------------------------------------------
    my $value;
    if ( $dir == 1 && $ph ) {
        $value = $c->{high};
    }
    elsif ( $dir == -1 && $pl ) {
        $value = $c->{low};
    }
    else {
        # La señal activa no coincide con dir — equivale a na en Pine.
        # El dir ya fue actualizado arriba; solo salimos sin agregar pivot.
        $self->{_prev_dir} = $dir;
        $self->_debug_log(
            sprintf "i=%d  dir=%d  ph=%d pl=%d  => señal no coincide con dir, SKIP",
            $i, $dir, $ph, $pl
        ) if $self->{debug};
        return;
    }
    return unless defined $value;

    my $dir_changed = ( $dir != $self->{_prev_dir} );
    my $pivots      = $self->{_pivots};

    my $action;
    if ( !@$pivots || $dir_changed ) {
        _add_pivot( $pivots, $i, $value, $dir );
        $action = 'ADD';
    }
    else {
        my $before = $pivots->[-1]{price};
        _update_pivot( $pivots, $i, $value, $dir );
        $action = ( $pivots->[-1]{price} != $before ) ? 'UPDATE_EXTEND' : 'UPDATE_NOOP';
    }

    # --- Modo debug barra-por-barra ---
    if ( $self->{debug} ) {
        my $live   = @$pivots ? $pivots->[-1] : undef;
        my $conf_n = @$pivots > 1 ? @$pivots - 1 : 0;
        my $conf   = $conf_n > 0 ? $pivots->[-2] : undef;
        $self->_debug_log(
            sprintf "i=%d  dir=%d(chg=%d)  ph=%d pl=%d  val=%.5f  action=%s  "
                  . "live=[%s@%s %.5f]  confirmed=[%s@%s %.5f]  total_pivots=%d",
            $i, $dir, $dir_changed, $ph, $pl, $value, $action,
            ( $live   ? $live->{kind}   : 'na' ),
            ( $live   ? $live->{index}  : 'na' ),
            ( $live   ? $live->{price}  : 0    ),
            ( $conf   ? $conf->{kind}   : 'na' ),
            ( $conf   ? $conf->{index}  : 'na' ),
            ( $conf   ? $conf->{price}  : 0    ),
            scalar(@$pivots),
        );
    }

    $self->{_prev_dir} = $dir;
    return;
}

sub _is_highest_bar {
    my ( $candles, $i, $period ) = @_;
    return 0 if $i < $period - 1;

    my $hi = $candles->[$i]{high};
    return 0 unless defined $hi;

    for my $j ( $i - $period + 1 .. $i - 1 ) {
        my $other = $candles->[$j]{high};
        return 0 unless defined $other;
        return 0 if $other > $hi;
    }
    return 1;
}

sub _is_lowest_bar {
    my ( $candles, $i, $period ) = @_;
    return 0 if $i < $period - 1;

    my $lo = $candles->[$i]{low};
    return 0 unless defined $lo;

    for my $j ( $i - $period + 1 .. $i - 1 ) {
        my $other = $candles->[$j]{low};
        return 0 unless defined $other;
        return 0 if $other < $lo;
    }
    return 1;
}

sub _add_pivot {
    my ( $pivots, $index, $price, $dir ) = @_;
    push @$pivots, {
        index => $index,
        price => $price,
        kind  => $dir == 1 ? 'H' : 'L',
    };
    return;
}

sub _update_pivot {
    my ( $pivots, $index, $price, $dir ) = @_;
    return unless @$pivots;

    my $last = $pivots->[-1];
    if ( $dir == 1 && $price > $last->{price} ) {
        $last->{price} = $price;
        $last->{index} = $index;
        $last->{kind}  = 'H';
    }
    elsif ( $dir == -1 && $price < $last->{price} ) {
        $last->{price} = $price;
        $last->{index} = $index;
        $last->{kind}  = 'L';
    }
    return;
}

1;
