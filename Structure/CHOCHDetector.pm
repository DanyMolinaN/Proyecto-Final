package Market::Structure::CHOCHDetector;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        events => [],
        %args,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{events} = [];
    return $self;
}

# detect($break_seq) -> \@choch_events
# Filtra de la secuencia unificada de rupturas las que son CHoCH (cambio de
# caracter: ruptura en contra de la tendencia previa) y las formatea para el
# overlay (anclaje temporal via 'index', etiqueta via new_trend).
sub detect {
    my ($self, $break_seq, %args) = @_;
    my $events = [];
    return $events unless $break_seq && ref $break_seq eq 'ARRAY';

    for my $e (@$break_seq) {
        next unless $e && ref $e eq 'HASH';
        next unless ($e->{kind} || '') eq 'CHoCH';
        my $new_trend  = ($e->{direction} || '') eq 'bullish' ? 'bullish' : 'bearish';
        my $prev_trend = $new_trend eq 'bullish' ? 'bearish' : 'bullish';
        push @$events, {
            event_id           => $e->{event_id},
            type               => 'CHoCH',
            direction          => $e->{direction},
            new_trend          => $new_trend,
            previous_trend     => $prev_trend,
            level              => $e->{level},
            index              => $e->{index},            # vela de confirmacion
            break_index        => $e->{swing_index},      # swing roto
            confirmation_index => $e->{index},
            scope              => $e->{scope} || 'external',
            hierarchy          => $e->{hierarchy},
        };
    }

    $self->{events} = $events;
    return $events;
}

sub events { my ($self) = @_; return $self->{events} || []; }

1;
