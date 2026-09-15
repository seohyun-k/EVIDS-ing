// A1 coherent ISO under-report — logic smoke test.
//
// EVerest cannot be built in every environment, so this harness replicates the
// EXACT forge arithmetic from patches/A1_iso-coherent-underreport.patch and
// checks the attack invariants on a simulated CurrentDemand session:
//   1. DOWN direction : present <= target (reads as normal derating)
//   2. COHERENT       : energy(ISO) == integral(present power)  (ISO internally consistent)
//   3. VOLTAGE held   : ISO voltage == OCPP voltage
//   4. CROSS diverges : |present_current(ISO) - Current.Import(OCPP)| > RV04 tol (2%)
//   5. OCPP true      : OCPP keeps the real values (power meter untouched)
//   6. NO extra msgs  : forge emits 0 additional V2G messages (count confound-free)
//
// Build & run:  g++ -std=c++17 -O2 smoke_forge.cpp -o /tmp/a1smoke && A1_ATTACK=1 A1_FACTOR=0.8 /tmp/a1smoke
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cstdint>
#include <vector>

// ---- replica of a1_read_cfg() from the patch ----
static void a1_read_cfg(int* enabled, double* k, int* do_c, int* do_v, int* do_e) {
    static int inited = 0, en = 0, dc = 0, dv = 0, de = 0;
    static double kk = 1.0;
    if (!inited) {
        inited = 1;
        const char* e = getenv("A1_ATTACK");
        en = (e != NULL) && (e[0]=='1'||e[0]=='t'||e[0]=='T'||e[0]=='y'||e[0]=='Y');
        const char* f = getenv("A1_FACTOR");
        kk = (f != NULL) ? atof(f) : 1.0;
        const char* t = getenv("A1_TARGET");
        const char* tg = (t != NULL) ? t : "coherent";
        if (strcmp(tg, "coherent") == 0) { dc = 1; de = 1; }
        else { dc = (strstr(tg,"current")!=NULL); dv = (strstr(tg,"voltage")!=NULL); de = (strstr(tg,"energy")!=NULL); }
    }
    *enabled = en; *k = kk; *do_c = dc; *do_v = dv; *do_e = de;
}

struct Sample { double iso_I, iso_V; uint64_t iso_meter; double ocpp_I, ocpp_V; uint64_t ocpp_meter; };

int main() {
    const double TARGET_I = 20.0, TRUE_V = 400.0;   // EV requests 20 A @ 400 V
    const int N = 30; const double DT_H = 1.0/3600.0; // 1 s samples
    int en, dc, dv, de; double k;
    a1_read_cfg(&en, &k, &dc, &dv, &de);
    printf("cfg: enabled=%d k=%.3f do_current=%d do_voltage=%d do_energy=%d\n\n", en, k, dc, dv, de);

    std::vector<Sample> ses;
    double true_cum_Wh = 0;              // true cumulative Wh (power meter, unrounded)
    int iso_msgs = 0, ocpp_msgs = 0;
    for (int i = 0; i < N; i++) {
        double trueI = TARGET_I;                          // real delivered current (physics)
        true_cum_Wh += trueI * TRUE_V * DT_H;             // power meter integrates truth

        // --- OCPP side: power meter, untouched by the forge ---
        Sample s;
        s.ocpp_I = trueI; s.ocpp_V = TRUE_V; s.ocpp_meter = (uint64_t)llround(true_cum_Wh); ocpp_msgs++;

        // --- ISO side: res values, with the SAME forge as the patch ---
        double isoI = trueI; double isoV = TRUE_V; uint64_t isoMeter = (uint64_t)llround(true_cum_Wh);
        if (en && k != 1.0) {
            if (dc) isoI = (double)(long)lround(isoI * k);
            if (dv) isoV = (double)(long)lround(isoV * k);
            if (de) isoMeter = (uint64_t)llround((double)isoMeter * k);
        }
        s.iso_I = isoI; s.iso_V = isoV; s.iso_meter = isoMeter; iso_msgs++;
        ses.push_back(s);
    }

    const Sample& last = ses.back();
    // integral of ISO-reported present power over the session (Wh)
    double iso_int_Wh = 0; for (auto& s : ses) iso_int_Wh += s.iso_I * s.iso_V * DT_H;

    double rv04_gap = fabs(last.iso_I - last.ocpp_I) / last.ocpp_I * 100.0;
    double energy_coherence = (double)last.iso_meter / (iso_int_Wh <= 0 ? 1 : iso_int_Wh); // ~1 if consistent

    printf("%-28s ISO(reported)   OCPP(true)\n", "");
    printf("%-28s %8.2f A     %8.2f A\n", "present current",  last.iso_I, last.ocpp_I);
    printf("%-28s %8.2f V     %8.2f V\n", "present voltage",  last.iso_V, last.ocpp_V);
    printf("%-28s %8llu Wh    %8llu Wh\n\n", "cumulative energy", (unsigned long long)last.iso_meter, (unsigned long long)last.ocpp_meter);

    int pass = 1;
    auto check = [&](const char* name, bool ok, const char* detail){ printf(" [%s] %-42s %s\n", ok?"PASS":"FAIL", name, detail); if(!ok) pass=0; };
    char buf[128];

    snprintf(buf,sizeof buf,"present %.1f <= target %.1f", last.iso_I, TARGET_I);
    check("1 DOWN: present <= target (normal derating)", last.iso_I <= TARGET_I + 1e-9, buf);

    snprintf(buf,sizeof buf,"meter/integral ratio = %.4f", energy_coherence);
    check("2 COHERENT: energy == integral(present power)", fabs(energy_coherence-1.0) < 0.03, buf);

    snprintf(buf,sizeof buf,"ISO %.1f V == OCPP %.1f V", last.iso_V, last.ocpp_V);
    check("3 VOLTAGE held (ISO == OCPP)", fabs(last.iso_V-last.ocpp_V) < 1e-9, buf);

    snprintf(buf,sizeof buf,"gap = %.1f%% > 2%% tol", rv04_gap);
    check("4 CROSS diverges (RV04 current)", (en?rv04_gap>2.0:true), en?buf:"(attack off: n/a)");

    snprintf(buf,sizeof buf,"OCPP I=%.1f V=%.1f (unchanged)", last.ocpp_I, last.ocpp_V);
    check("5 OCPP true (power meter untouched)", fabs(last.ocpp_I-TARGET_I)<1e-9 && fabs(last.ocpp_V-TRUE_V)<1e-9, buf);

    snprintf(buf,sizeof buf,"iso_msgs=%d ocpp_msgs=%d (no extra)", iso_msgs, ocpp_msgs);
    check("6 NO extra messages (count confound-free)", iso_msgs==N && ocpp_msgs==N, buf);

    printf("\n== SMOKE %s ==\n", pass?"PASS":"FAIL");
    return pass?0:1;
}
