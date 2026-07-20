package Market::Overlays::TrendChannelOverlay;

use strict;
use warnings;

use constant MAX_DRAW_CHANNELS => 6;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data     => undef,
        canvas   => $args{canvas},
        scale    => $args{scale},
        settings => $args{settings},
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

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    return unless $canvas;
    $canvas->delete('overlay_trend_channel');
}

sub draw {
    my ($self, %args) = @_;
    my $canvas    = $args{canvas} || $self->{canvas};
    my $scale     = $args{scale}  || $self->{scale};
    my $data      = $args{data}   || $self->{data};
    my $start_idx = $args{start_idx};
    my $end_idx   = $args{end_idx};
    
    return unless $canvas && $scale && $data;
    
    $self->clear($canvas);
    
    return $self if $self->{settings}
        && $self->{settings}->can('enabled')
        && !$self->{settings}->enabled('show_trend_channel');

    my $channels = $data->{channels} || [];
    return unless @$channels;

    my $ref_idx = defined $end_idx ? $end_idx : undef;
    my $draw_count = 0;

    for my $channel (@$channels) {
        last if ++$draw_count > MAX_DRAW_CHANNELS;
        my $type = $channel->{type};
        my $state = $channel->{state};
        
        my $sup_p1 = $channel->{support}{pivot1};
        my $res_p1 = $channel->{resistance}{pivot1};
        my $sup_end = $channel->{support}{end_index};
        
        # Extender visualmente hasta ref_idx o invalidated_at
        my $draw_end_idx = $ref_idx;
        if ($state eq 'invalidated' && defined $channel->{invalidated_at}) {
            $draw_end_idx = $channel->{invalidated_at};
        }
        $draw_end_idx = $sup_end if !defined $draw_end_idx;
        
        next if defined $draw_end_idx && defined $start_idx && $draw_end_idx < $start_idx;
        next if defined $end_idx && $sup_p1->{index} > $end_idx;
        
        my $color = '#787b86'; # horizontal
        if ($type eq 'ascending') {
            $color = '#22ab94';
        } elsif ($type eq 'descending') {
            $color = '#f23645';
        }
        
        my $dash = undef;
        my $width = 2;
        my $stipple = undef;
        
        if ($state eq 'invalidated') {
            $dash = [4, 4];
            $width = 1;
            $stipple = 'gray50'; # workaround para opacidad en perl/tk nativo
        }
        
        # Support Line
        my $x1_sup = $scale->index_to_center_x($sup_p1->{index});
        my $y1_sup = $scale->value_to_y($sup_p1->{price});
        
        my $x2_sup = $scale->index_to_center_x($draw_end_idx);
        my $p2_sup = $sup_p1->{price} + $channel->{slope_support} * ($draw_end_idx - $sup_p1->{index});
        my $y2_sup = $scale->value_to_y($p2_sup);
        
        $canvas->createLine($x1_sup, $y1_sup, $x2_sup, $y2_sup,
            -fill => $color,
            -width => $width,
            -dash => $dash,
            -stipple => $stipple,
            -tags => ['overlay_trend_channel']
        );
        
        # Resistance Line
        my $x1_res = $scale->index_to_center_x($res_p1->{index});
        my $y1_res = $scale->value_to_y($res_p1->{price});
        
        my $x2_res = $scale->index_to_center_x($draw_end_idx);
        my $p2_res = $res_p1->{price} + $channel->{slope_resistance} * ($draw_end_idx - $res_p1->{index});
        my $y2_res = $scale->value_to_y($p2_res);
        
        $canvas->createLine($x1_res, $y1_res, $x2_res, $y2_res,
            -fill => $color,
            -width => $width,
            -dash => $dash,
            -stipple => $stipple,
            -tags => ['overlay_trend_channel']
        );
        
        # Midline (averaging prices)
        my $mid_p1 = ($sup_p1->{price} + $res_p1->{price} + $channel->{slope_resistance} * ($sup_p1->{index} - $res_p1->{index})) / 2;
        my $y1_mid = $scale->value_to_y($mid_p1);
        my $mid_p2 = ($p2_sup + $p2_res) / 2;
        my $y2_mid = $scale->value_to_y($mid_p2);
        
        $canvas->createLine($x1_sup, $y1_mid, $x2_sup, $y2_mid,
            -fill => $color,
            -width => 1,
            -dash => [2, 4],
            -stipple => $stipple,
            -tags => ['overlay_trend_channel']
        );
    }
    
    return $self;
}

1;
