package Market::Overlays::AnchoredVWAPOverlay;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data     => undef,
        canvas   => $args{canvas},
        scale    => $args{scale},
        elements => [],
        %args,
    };
    bless $self, $class;
    return $self;
}

sub set_data {
    my ($self, $data) = @_;
    $self->{data} = $data;
    return $self;
}

sub draw {
    my ($self, %args) = @_;
    my $canvas = $args{canvas} || $self->{canvas};
    my $scale  = $args{scale}  || $self->{scale};
    my $data   = $args{data}   || $self->{data};
    return unless $canvas && $scale && $data && ref($data) eq 'HASH';

    $self->clear($canvas);

    my $vwap = $data->{vwap};
    return $self unless defined $vwap;

    my $anchor_index = $data->{anchor_index};
    my $anchor_time  = $data->{anchor_time};
    my $upper_band   = $data->{upper_band};
    my $lower_band   = $data->{lower_band};

    my $price_y = $scale->value_to_y($vwap);
    my $x_start = $scale->index_to_center_x($anchor_index);
    my $x_end   = $scale->index_to_x($self->{scale}->{start_index} + ($self->{scale}->{width} / $self->{scale}->{candle_width}));
    $x_end = $scale->{width} - 8 if !defined $x_end || $x_end > ($scale->{width} || 0);

    $canvas->createLine($x_start, $price_y, $x_end, $price_y,
        -fill   => '#ff9800',
        -width  => 2,
        -dash   => [6, 4],
        -tags   => ['overlay_anchored_vwap'],
    );

    if (defined $upper_band) {
        my $upper_y = $scale->value_to_y($upper_band);
        $canvas->createLine($x_start, $upper_y, $x_end, $upper_y,
            -fill   => '#ff7043',
            -width  => 1,
            -dash   => [3, 3],
            -tags   => ['overlay_anchored_vwap'],
        );
    }
    if (defined $lower_band) {
        my $lower_y = $scale->value_to_y($lower_band);
        $canvas->createLine($x_start, $lower_y, $x_end, $lower_y,
            -fill   => '#ff7043',
            -width  => 1,
            -dash   => [3, 3],
            -tags   => ['overlay_anchored_vwap'],
        );
    }

    if (defined $anchor_time) {
        my $anchor_y = $scale->value_to_y($vwap);
        my $text = sprintf('VWAP @ %s', $anchor_time);
        $canvas->createText($x_start, $anchor_y - 12,
            -text   => $text,
            -anchor => 'sw',
            -fill   => '#ffb74d',
            -font   => 'Helvetica 8 bold',
            -tags   => ['overlay_anchored_vwap'],
        );
    }

    return $self;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    return unless $canvas && $canvas->can('delete');
    $canvas->delete('overlay_anchored_vwap');
    $self->{elements} = [];
    return $self;
}

1;
