<?php

namespace App\Observers;

use App\Models\Ticket;
use Illuminate\Support\Facades\Cache;

class TicketObserver
{
    /**
     * Invalide le cache des KPIs du dashboard à chaque écriture sur un ticket.
     * Correctif du bug : le cache 30 min ne se rafraîchissait jamais.
     */
    public function saved(Ticket $ticket): void
    {
        Cache::forget('dashboard.kpis');
    }

    public function deleted(Ticket $ticket): void
    {
        Cache::forget('dashboard.kpis');
    }
}