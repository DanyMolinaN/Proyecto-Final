package Market::Indicators::SMCStructures2;

# =============================================================================
# Market::Indicators::SMCStructures2
#
# Portado desde Proyecto_David/Market/Indicators/SMC_Structures2.pm.
# Motor de estructura SMC (leg/BOS/CHoCH), Fair Value Gaps y Order Blocks,
# replica 1:1 del script Pine "Smart Money Concepts Pro [Neon]" (LuxAlgo) +
# "SMC Structures and FVG" (LudoGH68).
#
# Se porta el motor COMPLETO de estructura (leg/BOS/CHoCH/Equal H-L) porque
# los Order Blocks dependen de el (storeOrderBlock() se dispara desde
# displayStructure() al confirmarse un BOS/CHoCH) -- no es separable.
#
# Adaptaciones para Kevin:
#   - Candle field: $c->{ts} (David) -> $c->{timestamp} (Kevin).
#   - Se agrega recompute($md) para el contrato de IndicatorManager de Kevin.
#   - Se OMITE la seccion MTF Levels (Previous D/W/M High-Low) del original
#     (dependia de Time::Moment y de _period_key/_chart_tf_seconds/
#     get_mtf_levels/get_mtf_daily_level/etc.): no fue pedida, y no la usan
#     ni FVG ni Order Blocks ni el resto del motor -- omitirla no afecta la
#     correccion de lo que si se pidio.
#   - Resto de la logica (leg(), getCurrentStructure(), displayStructure(),
#     Equal H/L, FVG, Order Blocks) es identica al original de David.
# =============================================================================

use strict;
use warnings;

use constant {
    BULLISH_LEG => 1,
    BEARISH_LEG => 0,
    BULLISH     => 1,
    BEARISH     => -1,
};

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        swing_len    => $args{swing_len}    // 50,
        internal_len => $args{internal_len} // 5,
        break_mode   => $args{break_mode}   // 'close',

        int_confluence => $args{int_confluence} // 0,

        _c      => [],
        _events => [],

        _leg_state_swing    => 0,
        _leg_state_internal => 0,
        _prev_leg_swing     => undef,
        _prev_leg_internal  => undef,

        _swing_high    => { currentLevel => undef, lastLevel => undef, crossed => 0, barIndex => undef },
        _swing_low     => { currentLevel => undef, lastLevel => undef, crossed => 0, barIndex => undef },
        _internal_high => { currentLevel => undef, lastLevel => undef, crossed => 0, barIndex => undef },
        _internal_low  => { currentLevel => undef, lastLevel => undef, crossed => 0, barIndex => undef },

        _swing_bias    => undef,
        _internal_bias => undef,

        _swing_labels => {},

        eq_len    => $args{eq_len}    // 3,
        eq_thresh => $args{eq_thresh} // 0.1,
        atr       => $args{atr},
        _leg_state_eq => 0,
        _prev_leg_eq  => undef,
        _equal_high => { currentLevel => undef, lastLevel => undef, crossed => 0, barIndex => undef },
        _equal_low  => { currentLevel => undef, lastLevel => undef, crossed => 0, barIndex => undef },
        _eq_events  => [],

        fvg_auto_thresh => $args{fvg_auto_thresh} // 1,
        fvg_extend      => $args{fvg_extend}      // 1,
        fvg_history_max => $args{fvg_history_max} // 5,
        fvg_reduce      => $args{fvg_reduce}      // 0,
        _fvgs          => [],
        _active_fvgs   => [],
        _fvg_delta_cum => 0,
        _fvg_alerts    => [],

        ob_filter    => $args{ob_filter}    // 'atr',
        ob_mitig_src => $args{ob_mitig_src} // 'highlow',
        atr_len      => $args{atr_len}      // 200,
        swing_ob_max    => $args{swing_ob_max}    // 100,
        internal_ob_max => $args{internal_ob_max} // 100,
        _swing_obs     => [],
        _internal_obs  => [],
        _tr_cum        => 0,
        _ob_mit_events => [],

        _parsed_highs => [],
        _parsed_lows  => [],
        _internal_bias_hist => [],

        _trailing_top           => undef,
        _trailing_bottom        => undef,
        _trailing_bar_index     => undef,
        _trailing_bar_index_bot => undef,
        _trailing_last_top_idx  => undef,
        _trailing_last_bot_idx  => undef,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_c}      = [];
    $self->{_events} = [];
    $self->{_leg_state_swing}    = 0;
    $self->{_leg_state_internal} = 0;
    $self->{_prev_leg_swing}     = undef;
    $self->{_prev_leg_internal}  = undef;
    $_->{currentLevel} = undef, $_->{lastLevel} = undef, $_->{crossed} = 0, $_->{barIndex} = undef
        for ( $self->{_swing_high}, $self->{_swing_low}, $self->{_internal_high}, $self->{_internal_low} );
    $self->{_swing_bias}    = undef;
    $self->{_internal_bias} = undef;
    $self->{_swing_labels}  = {};
    $self->{_internal_bias_hist} = [];
    $self->{_trailing_top} = undef;
    $self->{_trailing_bottom} = undef;
    $self->{_trailing_bar_index} = undef;
    $self->{_trailing_bar_index_bot} = undef;
    $self->{_trailing_last_top_idx} = undef;
    $self->{_trailing_last_bot_idx} = undef;
    $self->{_ob_mit_events} = [];

    $self->{_leg_state_eq} = 0;
    $self->{_prev_leg_eq}  = undef;
    $_->{currentLevel} = undef, $_->{lastLevel} = undef, $_->{crossed} = 0, $_->{barIndex} = undef
        for ( $self->{_equal_high}, $self->{_equal_low} );
    $self->{_eq_events} = [];

    $self->{_fvgs}          = [];
    $self->{_active_fvgs}   = [];
    $self->{_fvg_delta_cum} = 0;
    $self->{_fvg_alerts}    = [];

    $self->{_swing_obs}    = [];
    $self->{_internal_obs} = [];
    $self->{_tr_cum}       = 0;

    $self->{_parsed_highs} = [];
    $self->{_parsed_lows}  = [];
}

sub get_values { return []; }

# recompute($md): contrato IndicatorManager de Kevin.
sub recompute {
    my ( $self, $md ) = @_;
    return unless $md;
    $self->reset();
    my $size = $md->size // 0;
    for my $idx ( 0 .. $size - 1 ) {
        $self->update_at_index( $md, $idx );
    }
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->_process($c);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $c = $md->last_candle;
    return unless defined $c;
    $self->_process($c);
}

sub get_events       { return $_[0]->{_events}; }
sub processed_last   { return $#{ $_[0]->{_c} }; }
sub get_swing_labels { return $_[0]->{_swing_labels}; }
sub get_candle_at    { return $_[0]->{_c}[ $_[1] ]; }

sub _process {
    my ( $self, $c ) = @_;
    push @{ $self->{_c} }, $c;
    my $i = $#{ $self->{_c} };

    my $vol_measure = $self->{ob_filter} eq 'range'
        ? $self->_range_measure($i)
        : $self->_atr_at($i, $self->{atr_len});
    $vol_measure //= 0;
    my $high_vol_bar = ( $c->{high} - $c->{low} ) >= ( 2 * $vol_measure );
    my $parsed_high  = $high_vol_bar ? $c->{low}  : $c->{high};
    my $parsed_low   = $high_vol_bar ? $c->{high} : $c->{low};
    push @{ $self->{_parsed_highs} }, $parsed_high;
    push @{ $self->{_parsed_lows} },  $parsed_low;

    $self->_get_current_structure( $i, $self->{swing_len},    0, 0 );
    $self->_get_current_structure( $i, $self->{internal_len}, 0, 1 );
    $self->_get_current_structure( $i, $self->{eq_len},       1, 0 );

    if ( defined $self->{_trailing_top} ) {
        if ( $c->{high} >= $self->{_trailing_top} ) {
            $self->{_trailing_top}          = $c->{high};
            $self->{_trailing_last_top_idx} = $i;
        }
    }
    if ( defined $self->{_trailing_bottom} ) {
        if ( $c->{low} <= $self->{_trailing_bottom} ) {
            $self->{_trailing_bottom}       = $c->{low};
            $self->{_trailing_last_bot_idx} = $i;
        }
    }

    $self->_delete_order_blocks( $i, 1 );
    $self->_delete_order_blocks( $i, 0 );

    $self->_display_structure( $i, 1 );
    $self->_display_structure( $i, 0 );

    $self->_detect_fvg($i);
    $self->_update_fvgs($i);

    push @{ $self->{_internal_bias_hist} }, $self->{_internal_bias};
}

sub _leg_raw {
    my ( $self, $i, $size ) = @_;
    my $c = $self->{_c};
    return undef if $i - $size < 0;
    return undef if $i - $size + 1 < 0;

    my $ref_idx  = $i - $size;
    my $win_from = $i - $size + 1;
    my $win_to   = $i;
    return undef if $win_from < 0;

    my ( $hi_max, $lo_min );
    for my $k ( $win_from .. $win_to ) {
        my $h = $c->[$k]{high};
        my $l = $c->[$k]{low};
        $hi_max = $h if !defined $hi_max || $h > $hi_max;
        $lo_min = $l if !defined $lo_min || $l < $lo_min;
    }

    my $high_size = $c->[$ref_idx]{high};
    my $low_size  = $c->[$ref_idx]{low};

    my $new_high = $high_size > $hi_max;
    my $new_low  = $low_size  < $lo_min;

    return { new_high => $new_high, new_low => $new_low };
}

sub _get_current_structure {
    my ( $self, $i, $size, $equal_hl, $internal ) = @_;

    my $raw = $self->_leg_raw( $i, $size );
    return unless $raw;

    my ( $state_key, $prev_key ) = $equal_hl
        ? ( '_leg_state_eq', '_prev_leg_eq' )
        : $internal
        ? ( '_leg_state_internal', '_prev_leg_internal' )
        : ( '_leg_state_swing',    '_prev_leg_swing' );

    my $leg_state = $self->{$state_key};
    if ( $raw->{new_high} ) {
        $leg_state = BEARISH_LEG;
    }
    elsif ( $raw->{new_low} ) {
        $leg_state = BULLISH_LEG;
    }
    my $prev_leg = $self->{$prev_key};
    $self->{$prev_key}  = $leg_state;
    $self->{$state_key} = $leg_state;

    return unless defined $prev_leg;
    my $changed = ( $leg_state != $prev_leg );
    return unless $changed;

    my $is_low  = ( $leg_state - $prev_leg ) == 1;
    my $is_high = ( $leg_state - $prev_leg ) == -1;

    my $ref_idx = $i - $size;
    my $c = $self->{_c};

    if ($is_low) {
        my $p = $equal_hl ? $self->{_equal_low} : $internal ? $self->{_internal_low} : $self->{_swing_low};

        if ($equal_hl) {
            my $low_ref = $c->[$ref_idx]{low};
            if ( defined $p->{currentLevel} ) {
                my $atr_val = $self->_atr_at($i);
                if ( defined $atr_val && abs( $p->{currentLevel} - $low_ref ) < $self->{eq_thresh} * $atr_val ) {
                    push @{ $self->{_eq_events} }, {
                        kind     => 'EQL',
                        idx_from => $p->{barIndex},
                        idx_to   => $ref_idx,
                        price    => $low_ref,
                        level_from => $p->{currentLevel},
                        ts       => $c->[$i]{timestamp},
                    };
                }
            }
        }

        $p->{lastLevel}    = $p->{currentLevel};
        $p->{currentLevel} = $c->[$ref_idx]{low};
        $p->{crossed}      = 0;
        $p->{barIndex}     = $ref_idx;

        if ( !$internal && !$equal_hl ) {
            $self->{_trailing_bottom}        = $p->{currentLevel};
            $self->{_trailing_bar_index_bot} = $ref_idx;
            $self->{_trailing_last_bot_idx}  = $ref_idx;

            my $label = ( defined $p->{lastLevel} && $p->{currentLevel} < $p->{lastLevel} ) ? 'LL' : 'HL';
            $self->{_swing_labels}{$ref_idx} = {
                label => $label, price => $p->{currentLevel}, kind => 'L',
            };
        }
    }
    elsif ($is_high) {
        my $p = $equal_hl ? $self->{_equal_high} : $internal ? $self->{_internal_high} : $self->{_swing_high};

        if ($equal_hl) {
            my $high_ref = $c->[$ref_idx]{high};
            if ( defined $p->{currentLevel} ) {
                my $atr_val = $self->_atr_at($i);
                if ( defined $atr_val && abs( $p->{currentLevel} - $high_ref ) < $self->{eq_thresh} * $atr_val ) {
                    push @{ $self->{_eq_events} }, {
                        kind     => 'EQH',
                        idx_from => $p->{barIndex},
                        idx_to   => $ref_idx,
                        price    => $high_ref,
                        level_from => $p->{currentLevel},
                        ts       => $c->[$i]{timestamp},
                    };
                }
            }
        }

        $p->{lastLevel}    = $p->{currentLevel};
        $p->{currentLevel} = $c->[$ref_idx]{high};
        $p->{crossed}      = 0;
        $p->{barIndex}     = $ref_idx;

        if ( !$internal && !$equal_hl ) {
            $self->{_trailing_top}       = $p->{currentLevel};
            $self->{_trailing_bar_index} = $ref_idx;
            $self->{_trailing_last_top_idx} = $ref_idx;

            my $label = ( defined $p->{lastLevel} && $p->{currentLevel} > $p->{lastLevel} ) ? 'HH' : 'LH';
            $self->{_swing_labels}{$ref_idx} = {
                label => $label, price => $p->{currentLevel}, kind => 'H',
            };
        }
    }
}

sub _atr_at {
    my ( $self, $i, $period ) = @_;
    if ( !defined $period && $self->{atr} && $self->{atr}->can('get_values') ) {
        my $vals = $self->{atr}->get_values;
        return $vals->[$i] if $vals && defined $vals->[$i];
    }
    return $self->_fallback_atr( $i, $period );
}

sub _fallback_atr {
    my ( $self, $i, $period ) = @_;
    $period //= 14;
    return undef if $i < 1;
    my $c = $self->{_c};
    my $from = $i - $period + 1;
    $from = 1 if $from < 1;
    my $sum = 0; my $n = 0;
    for my $k ( $from .. $i ) {
        my $cur  = $c->[$k];
        my $prev = $c->[$k-1];
        my $tr = _true_range( $cur, $prev );
        $sum += $tr; $n++;
    }
    return $n > 0 ? $sum / $n : undef;
}

sub _true_range {
    my ( $cur, $prev ) = @_;
    my @vals = (
        $cur->{high} - $cur->{low},
        abs( $cur->{high} - $prev->{close} ),
        abs( $cur->{low}  - $prev->{close} ),
    );
    my $tr = $vals[0];
    for (@vals) { $tr = $_ if $_ > $tr; }
    return $tr;
}

sub _display_structure {
    my ( $self, $i, $internal ) = @_;
    my $c = $self->{_c};
    my $cur   = $c->[$i];
    my $prev  = $i > 0 ? $c->[ $i - 1 ] : undef;
    return unless $prev;

    my $bias_key = $internal ? '_internal_bias' : '_swing_bias';

    my ( $bullish_bar, $bearish_bar ) = ( 1, 1 );
    if ( $internal && $self->{int_confluence} ) {
        my $hi_minus_maxco = $cur->{high} - _max2( $cur->{close}, $cur->{open} );
        my $minco_minus_lo = _min2( $cur->{close}, $cur->{open} ) - $cur->{low};
        $bullish_bar = $hi_minus_maxco > $minco_minus_lo;
        $bearish_bar = $hi_minus_maxco < $minco_minus_lo;
    }

    my $ph = $internal ? $self->{_internal_high} : $self->{_swing_high};
    if ( defined $ph->{currentLevel} && !$ph->{crossed} ) {
        my $crossover = ( $prev->{close} <= $ph->{currentLevel} ) && ( $cur->{close} > $ph->{currentLevel} );

        my $extra_bull = 1;
        if ($internal) {
            $extra_bull = $self->{int_confluence}
                ? ( $self->{_internal_high}{currentLevel} != $self->{_swing_high}{currentLevel} && $bullish_bar )
                : 1;
        }

        if ( $crossover && $extra_bull ) {
            my $tag = ( defined $self->{$bias_key} && $self->{$bias_key} == BEARISH ) ? 'CHoCH' : 'BOS';
            $ph->{crossed} = 1;
            $self->{$bias_key} = BULLISH;

            push @{ $self->{_events} }, {
                type      => $tag,
                scope     => $internal ? 'internal' : 'swing',
                dir       => 'up',
                index     => $i,
                origin    => $ph->{barIndex},
                price     => $ph->{currentLevel},
                ts        => $cur->{timestamp},
                confirmed => 1,
            };

            $self->_store_order_block( $ph, $internal, 'bull' );
        }
    }

    my $pl = $internal ? $self->{_internal_low} : $self->{_swing_low};
    if ( defined $pl->{currentLevel} && !$pl->{crossed} ) {
        my $crossunder = ( $prev->{close} >= $pl->{currentLevel} ) && ( $cur->{close} < $pl->{currentLevel} );

        my $extra_bear = 1;
        if ($internal) {
            $extra_bear = $self->{int_confluence}
                ? ( $self->{_internal_low}{currentLevel} != $self->{_swing_low}{currentLevel} && $bearish_bar )
                : 1;
        }

        if ( $crossunder && $extra_bear ) {
            my $tag = ( defined $self->{$bias_key} && $self->{$bias_key} == BULLISH ) ? 'CHoCH' : 'BOS';
            $pl->{crossed} = 1;
            $self->{$bias_key} = BEARISH;

            push @{ $self->{_events} }, {
                type      => $tag,
                scope     => $internal ? 'internal' : 'swing',
                dir       => 'down',
                index     => $i,
                origin    => $pl->{barIndex},
                price     => $pl->{currentLevel},
                ts        => $cur->{timestamp},
                confirmed => 1,
            };

            $self->_store_order_block( $pl, $internal, 'bear' );
        }
    }
}

sub _max2 { return $_[0] > $_[1] ? $_[0] : $_[1]; }
sub _min2 { return $_[0] < $_[1] ? $_[0] : $_[1]; }

sub _detect_fvg {
    my ( $self, $i ) = @_;
    return if $i < 3;
    my $c = $self->{_c};

    my $high3 = $c->[$i-3]{high};
    my $low3  = $c->[$i-3]{low};
    my $high1 = $c->[$i-1]{high};
    my $low1  = $c->[$i-1]{low};

    my $bull_fvg = $high3 < $low1;
    my $bear_fvg = $low3  > $high1;

    if ($bull_fvg) {
        my $fvg = {
            dir => 'bull', idx_start => $i - 2, created => $i,
            top => $low1, bottom => $high3, mid => ( $low1 + $high3 ) / 2,
            state => 'active', mitig_at => undef, alerted => 0,
        };
        push @{ $self->{_fvgs} },        $fvg;
        push @{ $self->{_active_fvgs} }, $fvg;
        $self->_trim_fvg_history;
    }
    if ($bear_fvg) {
        my $fvg = {
            dir => 'bear', idx_start => $i - 2, created => $i,
            top => $low3, bottom => $high1, mid => ( $low3 + $high1 ) / 2,
            state => 'active', mitig_at => undef, alerted => 0,
        };
        push @{ $self->{_fvgs} },        $fvg;
        push @{ $self->{_active_fvgs} }, $fvg;
        $self->_trim_fvg_history;
    }
}

sub _trim_fvg_history {
    my ($self) = @_;
    my $active = $self->{_active_fvgs};
    while ( scalar(@$active) > $self->{fvg_history_max} + 1 ) {
        my $oldest = shift @$active;
        $oldest->{state} = 'deleted';
    }
}

sub _update_fvgs {
    my ( $self, $i ) = @_;
    return unless @{ $self->{_active_fvgs} };
    my $cur = $self->{_c}[$i];
    my @keep;
    for my $f ( @{ $self->{_active_fvgs} } ) {
        if ( $f->{dir} eq 'bull' ) {
            if ( $cur->{low} <= $f->{bottom} ) {
                $f->{state} = 'deleted'; $f->{mitig_at} = $i;
                next;
            }
            if ( $cur->{low} < $f->{top} ) {
                $f->{state} = 'mitigated';
                $f->{mitig_at} //= $i;
                unless ( $f->{alerted} ) {
                    push @{ $self->{_fvg_alerts} }, {
                        kind => 'FVGMit', dir => $f->{dir}, index => $i, ts => $cur->{timestamp}, fvg => $f,
                    };
                    $f->{alerted} = 1;
                }
                $f->{top} = $cur->{low} if $self->{fvg_reduce};
            }
        }
        else {
            if ( $cur->{high} >= $f->{top} ) {
                $f->{state} = 'deleted'; $f->{mitig_at} = $i;
                next;
            }
            if ( $cur->{high} > $f->{bottom} ) {
                $f->{state} = 'mitigated';
                $f->{mitig_at} //= $i;
                unless ( $f->{alerted} ) {
                    push @{ $self->{_fvg_alerts} }, {
                        kind => 'FVGMit', dir => $f->{dir}, index => $i, ts => $cur->{timestamp}, fvg => $f,
                    };
                    $f->{alerted} = 1;
                }
                $f->{bottom} = $cur->{high} if $self->{fvg_reduce};
            }
        }
        push @keep, $f;
    }
    $self->{_active_fvgs} = \@keep;
}

sub get_fvgs       { return $_[0]->{_fvgs}; }
sub get_fvg_alerts { return $_[0]->{_fvg_alerts}; }
sub get_eq_events  { return $_[0]->{_eq_events}; }

sub _store_order_block {
    my ( $self, $p, $internal, $bias ) = @_;
    return unless defined $p->{barIndex};

    my $from = $p->{barIndex};
    my $to   = $self->processed_last;
    return if $from > $to;

    my $ph = $self->{_parsed_highs};
    my $pl = $self->{_parsed_lows};

    my $idx;
    if ( $bias eq 'bear' ) {
        my $max_v;
        for my $k ( $from .. $to ) {
            next unless defined $ph->[$k];
            if ( !defined $max_v || $ph->[$k] > $max_v ) { $max_v = $ph->[$k]; $idx = $k; }
        }
    }
    else {
        my $min_v;
        for my $k ( $from .. $to ) {
            next unless defined $pl->[$k];
            if ( !defined $min_v || $pl->[$k] < $min_v ) { $min_v = $pl->[$k]; $idx = $k; }
        }
    }
    return unless defined $idx;

    my $c = $self->{_c}[$idx];
    my $ob = {
        barHigh  => $ph->[$idx],
        barLow   => $pl->[$idx],
        barIndex => $idx,
        ts       => $c->{timestamp},
        bias     => $bias,
        origin_pivot_index => $p->{barIndex},
    };

    my $list_key = $internal ? '_internal_obs' : '_swing_obs';
    my $max_key  = $internal ? 'internal_ob_max' : 'swing_ob_max';
    my $obs = $self->{$list_key};

    pop @$obs if scalar(@$obs) >= $self->{$max_key};
    unshift @$obs, $ob;
}

sub _delete_order_blocks {
    my ( $self, $i, $internal ) = @_;
    my $list_key = $internal ? '_internal_obs' : '_swing_obs';
    my $obs = $self->{$list_key};
    return unless @$obs;

    my $c = $self->{_c}[$i];
    my ( $bear_mit_src, $bull_mit_src ) = $self->{ob_mitig_src} eq 'close'
        ? ( $c->{close}, $c->{close} )
        : ( $c->{high},  $c->{low} );

    my @keep;
    for my $ob (@$obs) {
        my $crossed = 0;
        if ( $ob->{bias} eq 'bear' && $bear_mit_src > $ob->{barHigh} ) {
            $crossed = 1;
        }
        elsif ( $ob->{bias} eq 'bull' && $bull_mit_src < $ob->{barLow} ) {
            $crossed = 1;
        }
        if ($crossed) {
            push @{ $self->{_ob_mit_events} }, {
                scope => $internal ? 'internal' : 'swing',
                bias  => $ob->{bias},
                index => $i,
                ts    => $c->{timestamp},
                ob    => $ob,
            };
        }
        push @keep, $ob unless $crossed;
    }
    $self->{$list_key} = \@keep;
}

sub _range_measure {
    my ( $self, $i ) = @_;
    my $c = $self->{_c};
    if ( $i >= 1 ) {
        $self->{_tr_cum} += _true_range( $c->[$i], $c->[$i-1] );
    }
    else {
        $self->{_tr_cum} += ( $c->[$i]{high} - $c->[$i]{low} );
    }
    my $n = $i > 0 ? $i : 1;
    return $self->{_tr_cum} / $n;
}

sub get_swing_order_blocks    { return $_[0]->{_swing_obs}; }
sub get_internal_order_blocks { return $_[0]->{_internal_obs}; }

sub get_internal_bias_at {
    my ( $self, $i ) = @_;
    return $self->{_internal_bias_hist}[$i];
}

sub get_trailing_extremes {
    my ($self) = @_;
    return undef unless defined $self->{_trailing_top} && defined $self->{_trailing_bottom};

    my $bias = $self->{_swing_bias};

    return {
        top              => $self->{_trailing_top},
        bottom           => $self->{_trailing_bottom},
        top_origin_index => $self->{_trailing_bar_index},
        bot_origin_index => $self->{_trailing_bar_index_bot},
        top_last_index   => $self->{_trailing_last_top_idx},
        bot_last_index   => $self->{_trailing_last_bot_idx},
        top_label        => ( defined $bias && $bias == BEARISH ) ? 'Strong High' : 'Weak High',
        bot_label        => ( defined $bias && $bias == BULLISH ) ? 'Strong Low'  : 'Weak Low',
    };
}

sub get_ob_mit_events { return $_[0]->{_ob_mit_events}; }

sub get_alerts_at {
    my ( $self, $i ) = @_;
    my %a = map { $_ => 0 } qw(
        intBullBOS intBearBOS intBullCHoCH intBearCHoCH
        swBullBOS  swBearBOS  swBullCHoCH  swBearCHoCH
        intBullOBMit intBearOBMit swBullOBMit swBearOBMit
        eqHighs eqLows bullFVG bearFVG fvgMitigated
    );

    for my $e ( @{ $self->{_events} } ) {
        next unless $e->{index} == $i;
        my $scope = $e->{scope} eq 'internal' ? 'int' : 'sw';
        my $dir   = $e->{dir}  eq 'up' ? 'Bull' : 'Bear';
        my $kind  = $e->{type} eq 'CHoCH' ? 'CHoCH' : 'BOS';
        $a{ "$scope$dir$kind" } = 1;
    }

    for my $e ( @{ $self->{_ob_mit_events} } ) {
        next unless $e->{index} == $i;
        my $scope = $e->{scope} eq 'internal' ? 'int' : 'sw';
        my $dir   = $e->{bias}  eq 'bull' ? 'Bull' : 'Bear';
        $a{ "$scope${dir}OBMit" } = 1;
    }

    for my $e ( @{ $self->{_eq_events} } ) {
        next unless $e->{idx_to} == $i;
        $a{ $e->{kind} eq 'EQH' ? 'eqHighs' : 'eqLows' } = 1;
    }

    for my $f ( @{ $self->{_fvgs} } ) {
        next unless $f->{created} == $i;
        $a{ $f->{dir} eq 'bull' ? 'bullFVG' : 'bearFVG' } = 1;
    }

    for my $e ( @{ $self->{_fvg_alerts} } ) {
        next unless $e->{index} == $i;
        $a{fvgMitigated} = 1;
    }

    return \%a;
}

1;
