package Market::Concepts::DSVWAP::EventBus;

use strict;
use warnings;

# =============================================================================
# Modulo: Market::Concepts::DSVWAP::EventBus
# Responsabilidad: Rutea los eventos sincrónicamente a los componentes suscritos.
# Es el núcleo de la máquina de estados. Garantiza orden y desacoplamiento.
# Complejidad: O(1) por despacho de evento por listener.
# =============================================================================

sub new {
    my ($class) = @_;
    my $self = {
        listeners => {}, # { event_type => [ sub1, sub2, ... ] }
    };
    bless $self, $class;
    return $self;
}

# subscribe($event_type, $callback)
# Añade un listener para un tipo de evento específico.
sub subscribe {
    my ($self, $event_type, $callback) = @_;
    $self->{listeners}{$event_type} ||= [];
    push @{ $self->{listeners}{$event_type} }, $callback;
}

# dispatch($event)
# Despacha un evento a todos los callbacks registrados sincrónicamente.
sub dispatch {
    my ($self, $event) = @_;
    my $type = $event->{type};
    return unless $self->{listeners}{$type};
    
    foreach my $callback (@{ $self->{listeners}{$type} }) {
        $callback->($event);
    }
}

# clear()
# Elimina todos los listeners (usado en re-inicializaciones).
sub clear {
    my ($self) = @_;
    $self->{listeners} = {};
}

1;
