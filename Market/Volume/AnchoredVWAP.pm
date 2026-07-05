package Market::Volume::AnchoredVWAP;

use strict;
use warnings;

use Market::Volume::VWAPCalculator;
use Market::Volume::AnchorResolver;
use Market::Volume::SessionAnchors;

sub new {
    my ($class, %args) = @_;
    my $self = {
        vwap_calculator => $args{vwap_calculator} || Market::Volume::VWAPCalculator->new(%{ $args{vwap_config} || {} }),
        anchor_resolver => $args{anchor_resolver} || Market::Volume::AnchorResolver->new(
            market_data     => $args{market_data},
            structure_engine => $args{structure_engine},
            concept_engines  => $args{concept_engines} || {},
        ),
        session_anchors => $args{session_anchors} || Market::Volume::SessionAnchors->new(
            market_data => $args{market_data},
            tz_offset   => $args{tz_offset},
        ),
        market_data => $args{market_data},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub calculate {
    my ($self, $anchor, %args) = @_;
    return {} unless $self->{market_data};
    return {} unless $anchor;

    my $anchor_type = ref $anchor ? $anchor->{type} : undef;
    return {} unless $anchor_type;

    my $anchor_index;
    if ($anchor_type eq 'session_open') {
        my $anchors = $self->{session_anchors}->build_session_open_anchors(market_data => $self->{market_data});
        if ($anchor->{index}) {
            $anchor_index = $anchor->{index};
        }
        else {
            $anchor_index = $anchors->[0]{index} if $anchors && ref $anchors eq 'ARRAY' && @{ $anchors };
        }
    }
    else {
        $anchor_index = $self->{anchor_resolver}->resolve_anchor($anchor);
    }

    return {} unless defined $anchor_index;

    my $replay_controller = $args{replay_controller};
    my $total = $self->{market_data}->size();
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;

    if (defined $visible_limit && $anchor_index > $visible_limit) {
        return {};
    }

    my $result = $self->{vwap_calculator}->calculate(
        $self->{market_data},
        $anchor_index,
    );

    return {
        anchor        => $anchor,
        anchor_index  => $anchor_index,
        anchor_time   => $result->{anchor_time},
        vwap          => $result->{vwap},
        std_dev       => $result->{std_dev},
        upper_band    => $result->{upper_band},
        lower_band    => $result->{lower_band},
        total_volume  => $result->{total_volume},
        visible_limit => $visible_limit,
        metadata      => {
            timeframe => $args{timeframe} || $self->{market_data}->active_tf(),
        },
    };
}

1;
