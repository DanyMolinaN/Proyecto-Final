package Market::Overlays::OrderBlockOverlay;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data => undef,
        canvas => $args{canvas},
        scale => $args{scale},
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
    my $canvas    = $args{canvas} || $self->{canvas};
    my $scale     = $args{scale}  || $self->{scale};
    my $data      = $args{data}   || $self->{data};
    my $start_idx = $args{start_idx};
    my $end_idx   = $args{end_idx};
    return unless $canvas && $scale;
    return unless $data;

    $self->clear($canvas);
    my $blocks = $data->{blocks} || [];
    return $self unless ref($blocks) eq 'ARRAY';

    my $total_received = scalar(@$blocks);
    my $discarded_invalid = 0;
    my $discarded_viewport = 0;
    my $rendered = 0;

    for my $block (@$blocks) {
        next unless $block && ref($block) eq 'HASH';
        my $idx = $block->{index} // $block->{created_index};
        my $price = $block->{price} // $block->{value};
        my $type = $block->{type};
        unless (defined $idx && defined $price && defined $type) {
            $discarded_invalid++;
            next;
        }
        if (defined $start_idx && $idx < $start_idx) {
            $discarded_viewport++;
            next;
        }
        if (defined $end_idx && $idx > $end_idx) {
            $discarded_viewport++;
            next;
        }

        my $label = $type eq 'bullish' ? 'OB+' : $type eq 'bearish' ? 'OB-' : 'OB';
        my $fill = $type eq 'bearish' ? '#ff5252' : '#4caf50';
        my $x = $scale->index_to_center_x($idx);
        my $y = $scale->value_to_y($price);

        $canvas->createLine($x - 6, $y, $x + 6, $y,
            -fill => $fill, -width => 2, -tags => ['overlay_order_block']);
        $canvas->createText($x, $y + 10,
            -text   => $label,
            -anchor => 'n',
            -fill   => $fill,
            -font   => 'Helvetica 8 bold',
            -tags   => ['overlay_order_block'],
        );
        $rendered++;
    }

    $self->{smc_audit} = {
        total_received      => $total_received,
        discarded_by_viewport => $discarded_viewport,
        discarded_invalid   => $discarded_invalid,
        rendered            => $rendered,
    };

    return $self;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    $canvas->delete('overlay_order_block') if $canvas && $canvas->can('delete');
    $self->{elements} = [];
    return $self;
}

1;
