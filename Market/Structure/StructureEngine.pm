package Market::Structure::StructureEngine;

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

use Market::Indicators::Liquidity;
use Market::Indicators::ZigZagMTF;
use Market::Indicators::ZigZagVolumeProfile;
use Market::Structure::BOSDetector;
use Market::Structure::CHOCHDetector;

sub new {
    my ($class, %args) = @_;
    my $self = {
        liquidity => $args{liquidity} || Market::Indicators::Liquidity->new(),
        bos_detector => $args{bos_detector} || Market::Structure::BOSDetector->new(),
        choch_detector => $args{choch_detector} || Market::Structure::CHOCHDetector->new(),
        zigzag_internal => $args{zigzag_internal}
            || Market::Indicators::ZigZagMTF->new(
            resolution_minutes => Market::Indicators::ZigZagMTF::DEFAULT_RESOLUTION_MINUTES(),
            period             => Market::Indicators::ZigZagMTF::DEFAULT_PERIOD(),
            ),
        zigzag_external => $args{zigzag_external}
            || Market::Indicators::ZigZagVolumeProfile->new(
            deviation_pct => Market::Indicators::ZigZagVolumeProfile::DEFAULT_DEVIATION_PCT(),
            ),
        _zigzag_synced_to => -1,
        swings => [],
        internal_swings => [],
        external_swings => [],
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
    $self->{internal_swings} = [];
    $self->{external_swings} = [];
    $self->{trend} = 'neutral';
    $self->{breaks} = [];
    $self->{changes} = [];
    $self->{metadata} = {};
    $self->{_zigzag_synced_to} = -1;
    $self->{zigzag_internal}->reset() if $self->{zigzag_internal};
    $self->{zigzag_external}->reset() if $self->{zigzag_external};
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

    my $raw_source_swings = $liquidity_result->{swings} || [];
    $self->_sync_zigzag_engines( $market_data, $last_index );
    return $self->_finalize_structure_from_zigzag(
        $candles, $last_index, $visible_limit, $tol,
        timeframe       => $args{timeframe} || $market_data->active_tf(),
        raw_swing_count => scalar(@$raw_source_swings),
    );
}

# _scan_structure_breaks($swings, $candles, $last_index) -> \@events
# Solo swings con scope=external definen niveles de referencia para BOS/CHoCH.
sub _scan_structure_breaks {
    my ($self, $swings, $candles, $last_index, %args) = @_;
    my @events;
    return \@events unless $swings && @$swings && $candles && @$candles;
    my $scope = $args{scope} || 'external';

    my @sorted = sort { $a->{index} <=> $b->{index} }
        grep {
            ($_->{scope} // $scope) eq $scope
            && ($scope eq 'external' || (($_->{hierarchy} || '') ne 'Minor'))
        } @$swings;
    return \@events unless @sorted;

    my $si = 0;
    my ($rh, $rhi, $rh_hierarchy, $rl, $rli, $rl_hierarchy);
    my $trend = 0;
    my $id = 0;

    for (my $i = 0; $i <= $last_index; $i++) {
        while ($si <= $#sorted && $sorted[$si]{index} <= $i) {
            my $s = $sorted[$si];
            if ($s->{kind} eq 'high') {
                $rh = $s->{price}; $rhi = $s->{index}; $rh_hierarchy = $s->{hierarchy};
            }
            else {
                $rl = $s->{price}; $rli = $s->{index}; $rl_hierarchy = $s->{hierarchy};
            }
            $si++;
        }
        my $c = $candles->[$i];
        next unless $c;
        my $close = $c->{close};
        next unless defined $close;

        if (defined $rh && defined $rhi && $rhi < $i && $close > $rh) {
            my $kind = ($trend < 0 || $scope eq 'internal') ? 'CHoCH' : 'BOS';
            next if $scope eq 'internal' && $trend >= 0;
            push @events, {
                event_id     => ++$id,
                kind         => $kind,
                direction    => 'bullish',
                trend_before => $trend,
                level        => $rh,
                index        => $i,
                swing_index  => $rhi,
                scope        => $scope,
                hierarchy    => $rh_hierarchy,
            };
            $trend = 1;
            $rh = undef; $rhi = undef; $rh_hierarchy = undef;
        }
        elsif (defined $rl && defined $rli && $rli < $i && $close < $rl) {
            my $kind = ($trend > 0 || $scope eq 'internal') ? 'CHoCH' : 'BOS';
            next if $scope eq 'internal' && $trend <= 0;
            push @events, {
                event_id     => ++$id,
                kind         => $kind,
                direction    => 'bearish',
                trend_before => $trend,
                level        => $rl,
                index        => $i,
                swing_index  => $rli,
                scope        => $scope,
                hierarchy    => $rl_hierarchy,
            };
            $trend = -1;
            $rl = undef; $rli = undef; $rl_hierarchy = undef;
        }
    }
    return \@events;
}

sub structure {
    my ($self) = @_;
    return {
        swings          => $self->{swings},
        internal_swings => $self->{internal_swings},
        external_swings => $self->{external_swings},
        trend           => $self->{trend},
        breaks          => $self->{breaks},
        changes         => $self->{changes},
        metadata        => $self->{metadata},
    };
}
sub events { my ($self) = @_; return [ @{ $self->{breaks} }, @{ $self->{changes} } ]; }

# refresh_zigzag_structure($market_data, %args)
# Actualiza ZigZag incrementalmente hasta el indice actual (replay o live)
# y reconstruye swings/BOS/CHoCH sin recalcular Liquidity.
sub refresh_zigzag_structure {
    my ( $self, $market_data, %args ) = @_;
    return {} unless $market_data;

    my $replay_controller = $args{replay_controller};
    my $liquidity_result  = $args{liquidity_result};
    my $total = $market_data->size();
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;
    my $last_index = ( defined $visible_limit && $visible_limit >= 0 && $visible_limit < $total )
        ? $visible_limit
        : ( $total - 1 );
    $last_index = 0 if $last_index < 0;

    my $candles = [];
    for ( my $i = 0 ; $i <= $last_index ; $i++ ) {
        my $c = $market_data->get_candle($i);
        push @$candles, $c if $c;
    }

    my $tol = 1e-6;
    if ( $liquidity_result
        && $liquidity_result->{metadata}
        && defined $liquidity_result->{metadata}{tolerance} )
    {
        $tol = $liquidity_result->{metadata}{tolerance};
    }
    elsif ( $self->{metadata} && defined $self->{metadata}{tolerance} ) {
        $tol = $self->{metadata}{tolerance};
    }

    $self->_sync_zigzag_engines( $market_data, $last_index );
    return $self->_finalize_structure_from_zigzag(
        $candles, $last_index, $visible_limit, $tol,
        timeframe => $args{timeframe} || $market_data->active_tf(),
        raw_swing_count => $liquidity_result
        ? scalar( @{ $liquidity_result->{swings} || [] } )
        : ( $self->{metadata}{raw_swing_count} // 0 ),
    );
}

sub _filter_structural_swings {
    my ($self, $source_swings, $candles, $tol) = @_;
    return $self->_build_zigzag_from_engine( $tol, profile => 'external' );
}

sub _swing_candidates {
    my ($self, $source_swings) = @_;
    return [] unless $source_swings && ref $source_swings eq 'ARRAY' && @$source_swings;

    return [
        sort { ($a->{index} // 0) <=> ($b->{index} // 0) }
        grep {
            $_ && ref $_ eq 'HASH'
            && defined $_->{index}
            && defined $_->{price}
            && (($_->{type} || '') eq 'swing_high' || ($_->{type} || '') eq 'swing_low')
        } @$source_swings
    ];
}

sub _sync_zigzag_engines {
    my ( $self, $market_data, $target_index ) = @_;
    return unless $market_data && defined $target_index && $target_index >= 0;

    if ( defined $self->{_zigzag_synced_to}
        && $self->{_zigzag_synced_to} > $target_index )
    {
        $self->{zigzag_internal}->reset() if $self->{zigzag_internal};
        $self->{zigzag_external}->reset() if $self->{zigzag_external};
        $self->{_zigzag_synced_to} = -1;
    }

    my $from = ( $self->{_zigzag_synced_to} // -1 ) + 1;
    $from = 0 if $from < 0;

    for my $i ( $from .. $target_index ) {
        my $c = $market_data->get_candle($i);
        next unless $c;
        $self->{zigzag_internal}->update_at_index( $market_data, $i )
            if $self->{zigzag_internal};
        $self->{zigzag_external}->update_at_index( $market_data, $i )
            if $self->{zigzag_external};
    }

    $self->{_zigzag_synced_to} = $target_index;

    $self->{_zigzag_tentative} = {
        internal => $self->{zigzag_internal}
            ? $self->{zigzag_internal}->get_tentative_segment()
            : undef,
        external => $self->{zigzag_external}
            ? $self->{zigzag_external}->get_tentative_segment()
            : undef,
    };
    return $self;
}

sub _zigzag_engine_for {
    my ( $self, $profile ) = @_;
    return $profile eq 'internal'
        ? $self->{zigzag_internal}
        : $self->{zigzag_external};
}

sub _build_zigzag_from_engine {
    my ( $self, $tol, %args ) = @_;
    my $profile = $args{profile} || 'external';
    $self->{_structural_filter_metadata} = {};
    $self->{_zigzag_metadata} ||= {};

    my $engine = $self->_zigzag_engine_for($profile);
    return [] unless $engine;

    my $source_swings = $engine->can('pivots_as_swings')
        ? $engine->pivots_as_swings()
        : [];
    return [] unless $source_swings && @$source_swings;

    my @filtered = map { +{%$_} } @$source_swings;
    for my $i (0 .. $#filtered) {
        my $s = $filtered[$i];
        $s->{prominence} = _pivot_prominence(\@filtered, $i);
        $s->{distance} = _adjacent_distance(\@filtered, $i);
        $s->{depth} = _swing_depth(\@filtered, $i);
        $s->{structurally_confirmed} = ($i > 0 && $i < $#filtered) ? 1 : 0;
    }

    my %hierarchy_thresholds = _hierarchy_thresholds($tol, @filtered);
    for my $s (@filtered) {
        $s->{structure_rank} = _swing_hierarchy(
            $profile,
            $s->{prominence},
            $s->{distance},
            $s->{depth},
            $s->{structurally_confirmed},
            \%hierarchy_thresholds,
        );
    }

    my $metadata;
    if ( $profile eq 'internal' && $engine->isa('Market::Indicators::ZigZagMTF') ) {
        $metadata = {
            algorithm            => 'zzmtf_pivothigh_pivotlow',
            resolution_minutes   => $engine->{resolution_minutes}
                // Market::Indicators::ZigZagMTF::DEFAULT_RESOLUTION_MINUTES(),
            period               => $engine->{period}
                // Market::Indicators::ZigZagMTF::DEFAULT_PERIOD(),
            pivot_count          => scalar(@filtered),
            intermediate_prominence => $hierarchy_thresholds{intermediate},
            major_prominence        => $hierarchy_thresholds{major},
            tolerance_floor      => $tol,
        };
    }
    elsif ( $profile eq 'external' && $engine->isa('Market::Indicators::ZigZagVolumeProfile') ) {
        $metadata = {
            algorithm            => 'zzvp_deviation_fsm',
            deviation_pct        => $engine->{deviation_pct}
                // Market::Indicators::ZigZagVolumeProfile::DEFAULT_DEVIATION_PCT(),
            pivot_count          => scalar(@filtered),
            intermediate_prominence => $hierarchy_thresholds{intermediate},
            major_prominence        => $hierarchy_thresholds{major},
            tolerance_floor      => $tol,
        };
    }
    else {
        $metadata = {
            algorithm            => 'zigzag_engine',
            pivot_count          => scalar(@filtered),
            intermediate_prominence => $hierarchy_thresholds{intermediate},
            major_prominence        => $hierarchy_thresholds{major},
            tolerance_floor      => $tol,
        };
    }
    $self->{_zigzag_metadata}{$profile} = $metadata;
    $self->{_structural_filter_metadata} = $metadata if $profile eq 'external';

    return \@filtered;
}

sub _finalize_structure_from_zigzag {
    my ( $self, $candles, $last_index, $visible_limit, $tol, %meta ) = @_;

    my $internal_source_swings = $self->_build_zigzag_from_engine( $tol, profile => 'internal' );
    my $external_source_swings = $self->_build_zigzag_from_engine( $tol, profile => 'external' );

    my $internal_swings = $self->_classify_zigzag_swings(
        $internal_source_swings, $visible_limit, $tol, 'internal'
    );
    my $external_swings = $self->_classify_zigzag_swings(
        $external_source_swings, $visible_limit, $tol, 'external'
    );

    $self->_assign_swing_scopes($external_swings);
    $self->_reclassify_vs_external( $external_swings, $tol );
    $self->_assign_swing_scopes($external_swings);
    for my $s (@$external_swings) { $s->{scope} = 'external'; }
    for my $s (@$internal_swings) { $s->{scope} = 'internal'; }

    $self->{swings}          = $external_swings;
    $self->{internal_swings} = $internal_swings;
    $self->{external_swings} = $external_swings;
    $self->{trend}           = $self->_derive_trend($external_swings);

    my $break_seq = $self->_scan_structure_breaks(
        $external_swings, $candles, $last_index, scope => 'external'
    );
    my $micro_break_seq = $self->_scan_structure_breaks(
        $internal_swings, $candles, $last_index, scope => 'internal'
    );
    push @$break_seq, grep { ( $_->{kind} || '' ) eq 'CHoCH' } @$micro_break_seq;
    $self->{breaks}  = $self->{bos_detector}->detect($break_seq);
    $self->{changes} = $self->{choch_detector}->detect($break_seq);

    $self->{metadata} = {
        timeframe       => $meta{timeframe} || 'unknown',
        raw_swing_count => $meta{raw_swing_count} // 0,
        candidate_count => $meta{raw_swing_count} // 0,
        internal_count  => scalar(@$internal_swings),
        swing_count     => scalar(@$external_swings),
        external_count  => scalar(@$external_swings),
        visible_limit   => $visible_limit,
        bos_count       => scalar( @{ $self->{breaks} } ),
        choch_count     => scalar( @{ $self->{changes} } ),
        tolerance       => $tol,
        structural_filter => $self->{_structural_filter_metadata} || {},
        zigzag          => $self->{_zigzag_metadata} || {},
        zigzag_tentative => $self->{_zigzag_tentative} || {},
        show_internal   => 0,
    };

    return {
        swings          => $self->{swings},
        internal_swings => $self->{internal_swings},
        external_swings => $self->{external_swings},
        trend           => $self->{trend},
        breaks          => $self->{breaks},
        changes         => $self->{changes},
        metadata        => $self->{metadata},
    };
}

sub _classify_zigzag_swings {
    my ($self, $source_swings, $visible_limit, $tol, $scope) = @_;
    my $swings = [];
    return $swings unless $source_swings && ref $source_swings eq 'ARRAY';

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
            zigzag      => $scope,
            prominence  => $swing->{prominence},
            distance    => $swing->{distance},
            depth       => $swing->{depth},
            structurally_confirmed => $swing->{structurally_confirmed},
            hierarchy   => $swing->{structure_rank}
                || 'Minor',
        };
    }

    return $swings;
}

sub _pivot_prominence {
    my ($swings, $idx) = @_;
    return 0 unless $swings && ref $swings eq 'ARRAY';
    return 0 unless defined $idx && $idx >= 0 && $idx <= $#$swings;

    my $s = $swings->[$idx];
    return 0 unless $s && defined $s->{price};

    my @distances;
    if ($idx > 0 && defined $swings->[$idx - 1]{price}) {
        push @distances, abs($s->{price} - $swings->[$idx - 1]{price});
    }
    if ($idx < $#$swings && defined $swings->[$idx + 1]{price}) {
        push @distances, abs($s->{price} - $swings->[$idx + 1]{price});
    }
    return 0 unless @distances;

    my $prominence = $distances[0];
    for my $d (@distances) {
        $prominence = $d if $d < $prominence;
    }
    return $prominence;
}

sub _adjacent_distance {
    my ($swings, $idx) = @_;
    return 0 unless $swings && ref $swings eq 'ARRAY';
    return 0 unless defined $idx && $idx >= 0 && $idx <= $#$swings;
    my $s = $swings->[$idx];
    return 0 unless $s && defined $s->{index};

    my @distances;
    push @distances, abs($s->{index} - $swings->[$idx - 1]{index})
        if $idx > 0 && defined $swings->[$idx - 1]{index};
    push @distances, abs($s->{index} - $swings->[$idx + 1]{index})
        if $idx < $#$swings && defined $swings->[$idx + 1]{index};
    return 0 unless @distances;

    my $distance = $distances[0];
    for my $d (@distances) {
        $distance = $d if $d < $distance;
    }
    return $distance;
}

sub _swing_depth {
    my ($swings, $idx) = @_;
    return 0 unless $swings && ref $swings eq 'ARRAY';
    return 0 unless defined $idx && $idx >= 0 && $idx <= $#$swings;
    my $s = $swings->[$idx];
    return 0 unless $s && defined $s->{price};

    my @prices = grep { defined $_ } map { $_->{price} } @$swings;
    return 0 unless @prices;
    my ($min, $max) = ($prices[0], $prices[0]);
    for my $p (@prices) {
        $min = $p if $p < $min;
        $max = $p if $p > $max;
    }
    my $range = $max - $min;
    return 0 if $range <= 0;
    return abs($s->{price} - (($max + $min) / 2)) / $range;
}

sub _median {
    my @values = sort { $a <=> $b } grep { defined $_ } @_;
    return 0 unless @values;
    my $n = scalar @values;
    return $values[int($n / 2)] if $n % 2;
    return ($values[$n / 2 - 1] + $values[$n / 2]) / 2;
}

sub _lower_quartile {
    my @values = sort { $a <=> $b } grep { defined $_ } @_;
    return 0 unless @values;
    return $values[int(@values * 0.25)];
}

sub _upper_quartile {
    my @values = sort { $a <=> $b } grep { defined $_ } @_;
    return 0 unless @values;
    return $values[int(@values * 0.75)];
}

sub _hierarchy_thresholds {
    my ($tol, @source) = @_;
    my @swings = grep { $_ && ref $_ eq 'HASH' } @source;
    my @prominences = grep { defined $_ && $_ > 0 } map { $_->{prominence} } @swings;
    my @distances = grep { defined $_ && $_ > 0 } map { $_->{distance} } @swings;
    $tol = 0 if !defined $tol || $tol < 0;
    return (intermediate => 0, major => 0) unless @prominences;
    return (
        intermediate => _median(@prominences),
        major        => _upper_quartile(@prominences),
        atr          => $tol,
        distance     => _median(@distances),
        depth        => _median(grep { defined $_ } map { $_->{depth} } @swings),
    );
}

sub _swing_hierarchy {
    my ($profile, $prominence, $distance, $depth, $confirmed, $thresholds) = @_;
    $prominence //= 0;
    $distance //= 0;
    $depth //= 0;
    $confirmed //= 0;
    $thresholds ||= {};
    my $major = $thresholds->{major} // 0;
    my $intermediate = $thresholds->{intermediate} // 0;
    my $atr = $thresholds->{atr} // 0;
    my $median_distance = $thresholds->{distance} // 0;
    my $median_depth = $thresholds->{depth} // 0;

    my $prominent = $major > 0 && $prominence >= $major;
    my $structural = $intermediate > 0 && $prominence >= $intermediate;
    my $atr_confirmed = $atr > 0 && $prominence >= $atr;
    my $spaced = $median_distance > 0 && $distance >= $median_distance;

    return 'Major' if $confirmed && $prominent && $atr_confirmed && ($spaced || $depth >= $median_depth);
    return 'Intermediate' if $confirmed && ($structural || ($atr_confirmed && $spaced));
    return 'Minor';
}

sub _collapse_same_side_swings {
    my (@swings) = @_;
    my @out;
    for my $s (@swings) {
        if (@out && (($s->{type} || '') eq ($out[-1]{type} || ''))) {
            $out[-1] = $s if _more_extreme_swing($s, $out[-1]);
            next;
        }
        push @out, $s;
    }
    return @out;
}

sub _more_extreme_swing {
    my ($candidate, $current) = @_;
    return 0 unless $candidate && $current;
    my $type = $candidate->{type} || '';
    return ($candidate->{price} // 0) > ($current->{price} // 0) if $type eq 'swing_high';
    return ($candidate->{price} // 0) < ($current->{price} // 0) if $type eq 'swing_low';
    return 0;
}

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
