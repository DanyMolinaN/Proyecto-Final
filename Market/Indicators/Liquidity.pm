package Market::Indicators::Liquidity;

# =============================================================================
# Market::Indicators::Liquidity
# =============================================================================
# Motor de cálculo de liquidity puro (datos/indicadores) sin render ni UI.
# =============================================================================

=pod

=head1 NAME

Market::Indicators::Liquidity - motor de cálculo de liquidity sin UI.

=head1 SYNOPSIS

    my $engine = Market::Indicators::Liquidity->new();
    my $result = $engine->calculate($market_data);

    my $events = $engine->events();
    my $levels = $engine->levels();
    my $swings = $engine->swings();

=cut

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        k              => $args{k} || 3,
        atr_value      => $args{atr_value},
        atr_indicator  => $args{atr_indicator},
        swings         => [],
        eq_levels      => [],
        liquidity_levels => [],
        events         => [],
        metadata       => {},
        accept_bars    => $args{accept_bars},
        grab_window    => $args{grab_window},
        visible_only   => 0,
        replay_limit   => undef,
        cache          => {},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{swings} = [];
    $self->{eq_levels} = [];
    $self->{liquidity_levels} = [];
    $self->{events} = [];
    $self->{metadata} = {};
    $self->{replay_limit} = undef;
    $self->{cache} = {};
    return $self;
}

sub calculate {
    my ($self, $market_data, %args) = @_;
    return {} unless $market_data;

    my $candles = $self->_candles_for_analysis($market_data, %args);
    return {} unless $candles && @$candles;

    my $atr = $self->_atr_value($market_data, $candles, atr_index => $#$candles);
    my $tol = defined $self->{tolerance} ? $self->{tolerance} : ($atr * 0.10);
    $tol = 0.000001 if !defined $tol || $tol <= 0;

    my $replay_controller = $args{replay_controller};
    my $total_size = $market_data->size();
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total_size)
        : undef;
    $self->{replay_limit} = $visible_limit;

    my $reuse_cache = $self->{cache} && $self->{cache}->{candle_count} && scalar(@$candles) > $self->{cache}->{candle_count};
    if ($reuse_cache) {
        $self->{swings} = [ @{ $self->{cache}->{swings} || [] } ];
        $self->{eq_levels} = [ @{ $self->{cache}->{eq_levels} || [] } ];
        $self->{liquidity_levels} = [ @{ $self->{cache}->{liquidity_levels} || [] } ];
        $self->{events} = [ @{ $self->{cache}->{events} || [] } ];
        $self->_detect_swings_tail($candles, $self->{cache}->{candle_count});
    }
    else {
        $self->{swings} = [];
        $self->{eq_levels} = [];
        $self->{liquidity_levels} = [];
        $self->{events} = [];
        $self->_detect_swings($candles);
    }

    $self->_detect_eq_levels($candles, $tol);
    $self->_build_liquidity_levels($candles);
    $self->_process_liquidity_lifecycle($candles);
    $self->_apply_visibility_filter($visible_limit);

    $self->{metadata} = {
        timeframe => $args{timeframe} || $market_data->active_tf(),
        candle_count => scalar @$candles,
        atr => $atr,
        tolerance => $tol,
        visible_limit => $visible_limit,
    };

    $self->{cache} = {
        candle_count => scalar(@$candles),
        swings => [ @{ $self->{swings} } ],
        eq_levels => [ @{ $self->{eq_levels} } ],
        liquidity_levels => [ @{ $self->{liquidity_levels} } ],
        events => [ @{ $self->{events} } ],
    };

    return {
        swings => $self->{swings},
        eq_levels => $self->{eq_levels},
        liquidity_levels => $self->{liquidity_levels},
        events => $self->{events},
        metadata => $self->{metadata},
    };
}

sub events { my ($self) = @_; return $self->{events} || []; }
sub levels { my ($self) = @_; return $self->{liquidity_levels} || []; }
sub swings { my ($self) = @_; return $self->{swings} || []; }

sub apply_structure_filter {
    my ($self, $structure_data, $market_data, %args) = @_;
    return unless $structure_data && ref $structure_data eq 'HASH';

    my %validated;
    my @validated_swings;
    for my $scope (qw(internal external)) {
        my $key = $scope . '_swings';
        for my $sw (@{ $structure_data->{$key} || [] }) {
            next unless $sw && ref $sw eq 'HASH';
            next unless defined $sw->{index};
            next unless $self->_important_structural_swing($sw, $scope);
            $validated{ $sw->{index} } = {
                scope      => $scope,
                hierarchy  => $sw->{hierarchy} || ($scope eq 'external' ? 'Intermediate' : 'Minor'),
                prominence => $sw->{prominence},
                label      => $sw->{label},
            };
            push @validated_swings, { %$sw, scope => $scope };
        }
    }

    # Opción B: No filtrar EQH/EQL por jerarquía de estructura (Major/Intermediate).
    # Un Equal High/Low es un patrón de precio válido sin importar la jerarquía.
    my @kept_eq = @{ $self->{eq_levels} || [] };

    my $candles = $args{candles};
    if (!$candles && $market_data) {
        $candles = $self->_candles_for_analysis($market_data, replay_controller => $args{replay_controller});
    }

    $self->{liquidity_levels} = [];
    $self->{eq_levels} = \@kept_eq;
    $self->{events} = [];
    $self->_build_liquidity_levels($candles, swings => \@validated_swings, eq_levels => \@kept_eq)
        if $candles && @$candles;
    $self->_process_liquidity_lifecycle($candles)
        if $candles && @$candles;

    $self->{metadata}{structure_validated} = 1;
    $self->{metadata}{validated_swing_count} = scalar @validated_swings;
    $self->{metadata}{validated_level_count} = scalar @{ $self->{liquidity_levels} || [] };
    $self->{metadata}{validated_event_count} = scalar @{ $self->{events} || [] };

    return {
        swings => $self->{swings},
        eq_levels => $self->{eq_levels},
        liquidity_levels => $self->{liquidity_levels},
        events => $self->{events},
        metadata => $self->{metadata},
    };
}

sub _important_structural_swing {
    my ($self, $swing, $scope) = @_;
    return 0 unless $swing && ref $swing eq 'HASH';
    my $rank = $swing->{hierarchy} || '';
    return 1 if ($scope || '') eq 'external' && ($rank eq 'Major' || $rank eq 'Intermediate');
    return 1 if ($scope || '') eq 'internal' && $rank eq 'Major';
    return 0;
}

sub visible_only {
    my ($self, $flag) = @_;
    $self->{visible_only} = $flag ? 1 : 0;
    return $self->{visible_only};
}

sub _candles_for_analysis {
    my ($self, $market_data, %args) = @_;
    my $total = $market_data->size();
    return [] unless defined $total && $total > 0;

    my $limit = $args{limit};
    my $end = $total - 1;
    $end = $limit if defined $limit && $limit >= 0 && $limit < $end;

    my $replay_controller = $args{replay_controller};
    if ($replay_controller && $replay_controller->can('visible_limit')) {
        my $visible_limit = $replay_controller->visible_limit($total);
        $end = $visible_limit if defined $visible_limit && $visible_limit >= 0 && $visible_limit < $end;
    }

    my @candles;
    for (my $i = 0; $i <= $end; $i++) {
        my $c = $market_data->get_candle($i);
        push @candles, $c if $c;
    }
    return \@candles;
}

sub _atr_value {
    my ($self, $market_data, $candles, %args) = @_;
    return $self->{atr_value} if defined $self->{atr_value};

    my $idx = $args{atr_index};
    if (!defined $idx && $candles && @$candles) {
        $idx = $#$candles;
    }
    $idx = 0 unless defined $idx;

    my $atr = $self->{atr_indicator};
    if ($atr && $atr->can('get_values')) {
        my $values = $atr->get_values() || [];
        if (@$values) {
            my $offset = 0;
            if ($atr->can('get_offset')) {
                $offset = $atr->get_offset();
            }
            elsif (defined $atr->{period}) {
                $offset = $atr->{period} - 1;
            }
            my $atr_idx = $idx - $offset;
            $atr_idx = 0           if $atr_idx < 0;
            $atr_idx = $#$values  if $atr_idx > $#$values;
            return $values->[$atr_idx] if $atr_idx >= 0;
        }
    }

    return 0 unless $candles && @$candles;
    my $last = $candles->[-1];
    return 0 unless $last;
    return ($last->{high} - $last->{low}) || 0;
}

sub _detect_swings {
    my ($self, $candles) = @_;
    my $k = $self->{k} || 3;
    return unless $candles && @$candles;
    for (my $i = $k; $i < @$candles - $k; $i++) {
        my $c = $candles->[$i];
        next unless $c;
        my $high = $c->{high};
        my $low  = $c->{low};
        my $is_high = 1;
        my $is_low  = 1;
        for (my $j = $i - $k; $j <= $i + $k; $j++) {
            next if $j == $i;
            my $other = $candles->[$j];
            next unless $other;
            $is_high = 0 if $other->{high} >= $high;
            $is_low  = 0 if $other->{low} <= $low;
        }
        if ($is_high) {
            push @{ $self->{swings} }, {
                index => $i,
                price => $high,
                time => $c->{timestamp},
                type => 'swing_high',
                strength => 1,
            };
        }
        if ($is_low) {
            push @{ $self->{swings} }, {
                index => $i,
                price => $low,
                time => $c->{timestamp},
                type => 'swing_low',
                strength => 1,
            };
        }
    }
}

# _detect_eq_levels($candles, $tol)
# EQH/EQL: comparar solo swings CONSECUTIVOS del mismo tipo (no O(n^2) de todos
# los pares, que en datasets volatiles genera decenas de miles de niveles falsos).
sub _detect_eq_levels {
    my ($self, $candles, $tol) = @_;
    return unless $candles && @$candles;
    my $swings = $self->{swings} || [];

    my @highs = grep { $_->{type} eq 'swing_high' } @$swings;
    my @lows  = grep { $_->{type} eq 'swing_low'  } @$swings;

    for (my $a = 1; $a < @highs; $a++) {
        my $sa = $highs[$a - 1];
        my $sb = $highs[$a];
        next unless abs($sa->{price} - $sb->{price}) <= $tol;
        push @{ $self->{eq_levels} }, {
            first_index  => $sa->{index},
            second_index => $sb->{index},
            level        => ($sa->{price} + $sb->{price}) / 2,
            atr          => $tol,
            type         => 'EQH',
        };
    }
    for (my $a = 1; $a < @lows; $a++) {
        my $sa = $lows[$a - 1];
        my $sb = $lows[$a];
        next unless abs($sa->{price} - $sb->{price}) <= $tol;
        push @{ $self->{eq_levels} }, {
            first_index  => $sa->{index},
            second_index => $sb->{index},
            level        => ($sa->{price} + $sb->{price}) / 2,
            atr          => $tol,
            type         => 'EQL',
        };
    }
}

sub _build_liquidity_levels {
    my ($self, $candles, %args) = @_;
    return unless $candles && @$candles;
    $self->{liquidity_levels} = [];
    my $counter = 0;
    my $source_swings = $args{swings} || $self->{swings} || [];
    my $eq_levels = $args{eq_levels} || $self->{eq_levels} || [];

    for my $swing (@$source_swings) {
        next unless $swing && ref $swing eq 'HASH';
        next unless defined $swing->{index} && defined $swing->{price};
        my $source_type = $swing->{source_type} || $swing->{type} || '';
        next unless $source_type eq 'swing_high' || $source_type eq 'swing_low';
        my $level = {
            id            => 'L' . ++$counter,
            state         => 'Detected',
            price         => $swing->{price},
            origin_tf     => $self->{metadata}->{timeframe} || 'unknown',
            created_index => $swing->{index},
            last_touch    => $swing->{index},
            volume        => $self->_volume_for_index($candles, $swing->{index}),
            type          => $source_type eq 'swing_high' ? 'BSL' : 'SSL',
            side          => $source_type eq 'swing_high' ? 'buy' : 'sell',
            scope         => $swing->{scope} || 'external',
            hierarchy     => $swing->{hierarchy},
            prominence    => $swing->{prominence},
            structural_weight => undef,
            transitions   => [
                { state => 'Candidate', index => $swing->{index} },
                { state => 'Validated Swing', index => $swing->{index} },
                { state => 'Liquidity Candidate', index => $swing->{index} },
                { state => 'Detected', index => $swing->{index} },
            ],
        };
        $level->{structural_weight} = $self->_structural_weight($level);
        push @{ $self->{liquidity_levels} }, $level;
    }

    for my $eq (@$eq_levels) {
        my $type = $eq->{type} || 'EQH';
        push @{ $self->{liquidity_levels} }, {
            id            => 'L' . ++$counter,
            state         => 'Detected',
            price         => $eq->{level},
            origin_tf     => $self->{metadata}->{timeframe} || 'unknown',
            created_index => $eq->{second_index},
            last_touch    => $eq->{second_index},
            volume        => $self->_volume_for_index($candles, $eq->{second_index}),
            type          => $type,
            side          => ($type eq 'EQH') ? 'buy' : 'sell',
            eq_pair       => 1,
            scope         => 'external',
            hierarchy     => 'Intermediate',
            transitions   => [
                { state => 'Candidate', index => $eq->{second_index} },
                { state => 'Validated Swing', index => $eq->{second_index} },
                { state => 'Liquidity Candidate', index => $eq->{second_index} },
                { state => 'Detected', index => $eq->{second_index} },
            ],
        };
    }
}

# _process_liquidity_lifecycle($candles)
# Maquina de estados: Detected -> Swept -> Acceptance/Reclaimed -> Resolved
# Clasificacion final: Sweep, Grab o Run (spec 4.2 / 4.3).
sub _process_liquidity_lifecycle {
    my ($self, $candles) = @_;
    return unless $candles && @$candles;

    my $accept_bars = $self->{accept_bars} || $self->{k} || 1;
    my $grab_window = $self->{grab_window} || $self->{k} || 1;
    my @events;
    my $event_id = 0;

    for my $level (@{ $self->{liquidity_levels} || [] }) {
        next if $level->{eq_pair};    # EQH/EQL: solo linea guia, sin lifecycle
        my $price  = $level->{price};
        my $is_buy = ($level->{side} // '') eq 'buy'
                  || $level->{type} eq 'BSL' || $level->{type} eq 'EQH';
        my $from   = ($level->{created_index} // 0) + 1;

        my $state         = 'Detected';
        my @transitions   = @{ $level->{transitions} || [] };
        my $resolution;
        my $resolve_index;
        my $sweep_index;

        for (my $i = $from; $i < @$candles; $i++) {
            my $c = $candles->[$i];
            next unless $c;

            if ($state eq 'Detected') {
                my $crossed = $is_buy ? ($c->{high} > $price) : ($c->{low} < $price);
                next unless $crossed;

                $state       = 'Swept';
                $sweep_index = $i;
                push @transitions, { state => 'Swept', index => $i };
                $level->{last_touch} = $i;

                # Sweep en la misma vela de penetracion
                if ($is_buy && $c->{high} > $price && $c->{close} < $price) {
                    $resolution    = 'Sweep';
                    $resolve_index = $i;
                    push @transitions,
                        { state => 'Reclaimed', index => $i },
                        { state => 'Resolved', index => $i, classification => 'Sweep' };
                    $state = 'Resolved';
                    last;
                }
                if (!$is_buy && $c->{low} < $price && $c->{close} > $price) {
                    $resolution    = 'Sweep';
                    $resolve_index = $i;
                    push @transitions,
                        { state => 'Reclaimed', index => $i },
                        { state => 'Resolved', index => $i, classification => 'Sweep' };
                    $state = 'Resolved';
                    last;
                }

                # Evaluar velas posteriores al barrido
                my $consec_out = 0;
                for (my $j = $i; $j < @$candles; $j++) {
                    my $cj = $candles->[$j];
                    next unless $cj;

                    my $outside = $is_buy ? ($cj->{close} > $price) : ($cj->{close} < $price);
                    my $inside  = $is_buy ? ($cj->{close} < $price) : ($cj->{close} > $price);

                    if ($outside) {
                        $consec_out++;
                        if ($consec_out == 1 && $state eq 'Swept') {
                            $state = 'Acceptance';
                            push @transitions, { state => 'Acceptance', index => $j };
                        }
                        if ($consec_out >= $accept_bars) {
                            $resolution    = 'Run';
                            $resolve_index = $j;
                            push @transitions, { state => 'Resolved', index => $j, classification => 'Run' };
                            $state = 'Resolved';
                            last;
                        }
                    }
                    else {
                        $consec_out = 0;
                    }

                    if ($inside && defined $sweep_index && ($j - $sweep_index) < $grab_window) {
                        $resolution    = 'Grab';
                        $resolve_index = $j;
                        push @transitions,
                            { state => 'Reclaimed', index => $j },
                            { state => 'Resolved', index => $j, classification => 'Grab' };
                        $state = 'Resolved';
                        last;
                    }

                    if ($inside && defined $sweep_index && ($j - $sweep_index) >= $grab_window) {
                        $resolution    = 'Sweep';
                        $resolve_index = $j;
                        push @transitions,
                            { state => 'Reclaimed', index => $j },
                            { state => 'Resolved', index => $j, classification => 'Sweep' };
                        $state = 'Resolved';
                        last;
                    }
                }
                last if $state eq 'Resolved';
            }
        }

        $level->{state}       = $state;
        $level->{transitions} = \@transitions;
        $level->{resolution}  = $resolution if defined $resolution;

        if ($resolution && defined $resolve_index) {
            push @events, {
                event_id  => ++$event_id,
                type      => $resolution,
                direction => $is_buy ? 'up' : 'down',
                start     => $sweep_index // $level->{created_index},
                end       => $resolve_index,
                price     => $price,
                level     => $price,
                level_id  => $level->{id},
                level_type => $level->{type},
            };
        }
    }

    $self->{events} = \@events;
}

sub _detect_swings_tail {
    my ($self, $candles, $from_index) = @_;
    my $k = $self->{k} || 3;
    return unless $candles && @$candles;
    for (my $i = $from_index; $i < @$candles - $k; $i++) {
        my $c = $candles->[$i];
        next unless $c;
        my $high = $c->{high};
        my $low  = $c->{low};
        my $is_high = 1;
        my $is_low = 1;
        for (my $j = $i - $k; $j <= $i + $k; $j++) {
            next if $j == $i;
            my $other = $candles->[$j];
            next unless $other;
            $is_high = 0 if $other->{high} >= $high;
            $is_low = 0 if $other->{low} <= $low;
        }
        if ($is_high) {
            push @{ $self->{swings} }, {
                index => $i,
                price => $high,
                time => $c->{timestamp},
                type => 'swing_high',
                strength => 1,
            };
        }
        if ($is_low) {
            push @{ $self->{swings} }, {
                index => $i,
                price => $low,
                time => $c->{timestamp},
                type => 'swing_low',
                strength => 1,
            };
        }
    }
}

sub _apply_visibility_filter {
    my ($self, $visible_limit) = @_;
    return unless $self->{visible_only};
    return unless defined $visible_limit && $visible_limit >= 0;

    $self->{swings} = [ grep { $_->{index} <= $visible_limit } @{ $self->{swings} || [] } ];
    $self->{eq_levels} = [ grep { $_->{first_index} <= $visible_limit && $_->{second_index} <= $visible_limit } @{ $self->{eq_levels} || [] } ];
    $self->{liquidity_levels} = [ grep { $_->{created_index} <= $visible_limit } @{ $self->{liquidity_levels} || [] } ];
    $self->{events} = [ grep { $_->{end} <= $visible_limit } @{ $self->{events} || [] } ];
}

sub _structural_weight {
    my ($self, $level) = @_;
    return 0 unless $level && ref $level eq 'HASH';
    my $tol = $self->{metadata}{tolerance} || 1;
    $tol = 1 if $tol <= 0;
    my $prominence = $level->{prominence} || 0;
    my $weight = $prominence / $tol;
    $weight += 1 if ($level->{scope} || '') eq 'external';
    $weight += 1 if $level->{eq_pair};
    return sprintf('%.4f', $weight) + 0;
}

sub _volume_for_index {
    my ($self, $candles, $index) = @_;
    return 0 unless $candles && @$candles && defined $index && $index >= 0 && $index < @$candles;
    my $c = $candles->[$index];
    return $c->{volume} || 0;
}

1;
