package Market::Volume::SessionAnchors;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        market_data => $args{market_data},
        tz_offset   => defined $args{tz_offset} ? $args{tz_offset} : ($args{market_data} ? $args{market_data}->get_tz_offset() : 0),
        %args,
    };
    bless $self, $class;
    return $self;
}

sub build_session_open_anchors {
    my ($self, %args) = @_;
    my $market_data = $args{market_data} || $self->{market_data};
    return [] unless $market_data;

    my $total = $market_data->size();
    return [] unless $total;

    my $tz = $self->{tz_offset} || 0;
    my @anchors;
    my $last_day;

    for my $index (0 .. $total - 1) {
        my $candle = $market_data->get_candle($index);
        next unless $candle && defined $candle->{timestamp};

        my $day = int(($candle->{timestamp} + $tz) / 86400);
        if (!defined $last_day || $day != $last_day) {
            push @anchors, { type => 'session_open', index => $index, timestamp => $candle->{timestamp} };
            $last_day = $day;
        }
    }

    return \@anchors;
}

sub session_open_anchors {
    my ($self) = @_;
    return $self->build_session_open_anchors();
}

1;
