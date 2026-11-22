#pragma once

// sim_steps (PAIN_SIM_STEPS): simulation steps per rendered frame. 2 is the
// game's own frame driver; 1 runs the one-step copy prepare_ppu.cmake makes.
// Call after ppu_recomp_register(), with the EBOOT loaded.
void install_sim_steps();
