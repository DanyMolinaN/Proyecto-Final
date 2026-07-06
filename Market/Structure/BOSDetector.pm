package Market::Structure::BOSDetector;

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

# detect($break_seq) -> \@bos_events
# Filtra de la secuencia unificada de rupturas las que son BOS (continuacion de
# tendencia) y las formatea para el overlay (anclaje temporal via 'index').
sub detect {
    my ($self, $break_seq, %args) = @_;
    my $events = [];
    return $events unless $break_seq && ref $break_seq eq 'ARRAY';

    for my $e (@$break_seq) {
        next unless $e && ref $e eq 'HASH';
        next unless ($e->{kind} || '') eq 'BOS';
        push @$events, {
            event_id           => $e->{event_id},
            type               => 'BOS',
            direction          => $e->{direction},
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
