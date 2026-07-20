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

    my $settings = $args{settings} || $self->{settings};
    if ($settings && $settings->can('enabled')) {
        return $self unless $settings->enabled('show_orderblocks');
    }

    $self->clear($canvas);
    my $blocks = $data->{blocks} || [];
    return $self unless ref($blocks) eq 'ARRAY';

    my $total_received = scalar(@$blocks);
    my $discarded_invalid = 0;
    my $discarded_viewport = 0;
    my $rendered = 0;

    for my $block (@$blocks) {
        next unless $block && ref($block) eq 'HASH';
        next if ($block->{state} || '') eq 'Invalidated';
        next if ($block->{state} || '') eq 'Mitigated';

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

        my $cw = $scale->index_to_center_x(1) - $scale->index_to_center_x(0);
        my $half = $cw > 0 ? $cw / 2 : 2;
        my $visual_idx = $idx + 1;
        my $x1 = $scale->index_to_center_x($visual_idx) - $half;
        
        my $draw_end = $block->{invalidated_index} // $block->{mitigated_index} // $end_idx // ($idx + 50);
        my $visual_draw_end = $draw_end + 1;
        $visual_draw_end = $end_idx if defined $end_idx && $visual_draw_end > $end_idx;
        my $x2 = $scale->index_to_center_x($visual_draw_end) + $half;
        $x2 = $x1 + ($half * 2) if $x2 <= $x1;
        
        my $high = $block->{high} // $price;
        my $low  = $block->{low}  // $price;
        my $y1 = $scale->value_to_y($high);
        my $y2 = $scale->value_to_y($low);
        ($y1, $y2) = ($y2, $y1) if $y1 > $y2;

        $canvas->createRectangle($x1, $y1, $x2, $y2,
            -fill    => $fill,
            -stipple => 'gray12',
            -outline => $fill,
            -width   => 1,
            -tags    => ['overlay_order_block'],
        );

        my $y_mid = ($y1 + $y2) / 2;
        $canvas->createText($x1 + 4, $y_mid,
            -text   => $label,
            -anchor => 'w',
            -fill   => $fill,
            -font   => 'Helvetica 7 bold',
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
