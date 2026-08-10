#include "mpc2000xl_all.h"

#include <kaitai/kaitaistream.h>

#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

int main(int argc, char **argv)
{
    if (argc != 2)
    {
        std::cerr << "usage: dump-mpc2000xl-all FILE.all\n";
        return 2;
    }

    std::ifstream input(argv[1], std::ios::binary);
    if (!input)
        throw std::runtime_error("cannot open ALL file");

    kaitai::kstream stream(&input);
    mpc2000xl_all_t all(&stream);
    all._read();

    std::cout << "master_tempo_tenths=" << all.sequencer()->master_tempo() << '\n';
    for (const auto &sequence : *all.sequences())
    {
        if (!sequence->body())
            continue;

        const auto *body = sequence->body();
        std::cout << "sequence,index=" << unsigned(body->index())
                  << ",name=" << sequence->name()
                  << ",bars=" << body->bar_count()
                  << ",last_tick=" << body->last_tick() << '\n';

        for (const auto &event : *body->events())
        {
            if (!event->note_event())
                continue;
            auto *note = event->note_event();
            std::cout << "note,tick=" << event->tick()
                      << ",track=" << event->track()
                      << ",note=" << unsigned(note->note())
                      << ",velocity=" << note->velocity()
                      << ",variation_type=" << unsigned(note->variation_type())
                      << ",variation_value=" << note->variation_value()
                      << '\n';
        }
    }
}
