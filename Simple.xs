#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <linux/perf_event.h>
#include <perf/evlist.h>
#include <perf/evsel.h>
#include <perf/cpumap.h>
#include <perf/threadmap.h>
#include <perf/mmap.h>
#include <perf/core.h>
#include <perf/event.h>

static int
libperf_print(enum libperf_print_level level,
              const char *fmt, va_list ap) {
  dTHX;
  SV *logger = get_sv("Linux::libperf::Simple::logger", 0);
  if (logger && SvOK(logger)) {
    /* plan to forward to a perl callback */
    /* something strange with the ap type here */
    SV *sv = sv_2mortal(vnewSVpvf(fmt, (va_list *)&ap));
    PerlIO_printf(PerlIO_stderr(), "Linux::libperf::Simple todo: %s", SvPV_nolen(sv));
  }
  return 0;
}

typedef struct {
  struct perf_thread_map *threads;
  struct perf_evlist *evlist;
} libperf_simple;

typedef libperf_simple *Linux__libperf__Simple;

struct my_perf_event_attr {
  const char *key;
  struct perf_event_attr attr;
};

static struct my_perf_event_attr
ev_attr[] =
  {
    {
      "cpu-cycles",
      {
        .type = PERF_TYPE_HARDWARE,
        .config = PERF_COUNT_HW_CPU_CYCLES,
        .read_format = PERF_FORMAT_TOTAL_TIME_ENABLED|PERF_FORMAT_TOTAL_TIME_ENABLED,
        .disabled = 1,
      }
    },
    {
      "instructions",
      {
        .type = PERF_TYPE_HARDWARE,
        .config = PERF_COUNT_HW_INSTRUCTIONS,
        .read_format = PERF_FORMAT_TOTAL_TIME_ENABLED|PERF_FORMAT_TOTAL_TIME_ENABLED,
        .disabled = 1,
      }
    },
    {
      "branch-instructions",
      {
        .type = PERF_TYPE_HARDWARE,
        .config = PERF_COUNT_HW_BRANCH_INSTRUCTIONS,
        .read_format = PERF_FORMAT_TOTAL_TIME_ENABLED|PERF_FORMAT_TOTAL_TIME_ENABLED,
        .disabled = 1,
      }
    },
    {
      "branch-misses",
      {
        .type = PERF_TYPE_HARDWARE,
        .config = PERF_COUNT_HW_BRANCH_MISSES,
        .read_format = PERF_FORMAT_TOTAL_TIME_ENABLED|PERF_FORMAT_TOTAL_TIME_ENABLED,
        .disabled = 1,
      }
    },
    {
      "bus-cycles",
      {
        .type = PERF_TYPE_HARDWARE,
        .config = PERF_COUNT_HW_BUS_CYCLES,
        .read_format = PERF_FORMAT_TOTAL_TIME_ENABLED|PERF_FORMAT_TOTAL_TIME_ENABLED,
        .disabled = 1,
      }
    },
    {
      "cache-misses",
      {
        .type = PERF_TYPE_HARDWARE,
        .config = PERF_COUNT_HW_CACHE_MISSES,
        .read_format = PERF_FORMAT_TOTAL_TIME_ENABLED|PERF_FORMAT_TOTAL_TIME_ENABLED,
        .disabled = 1,
      }
    },
    {
      "cache-references",
      {
        .type = PERF_TYPE_HARDWARE,
        .config = PERF_COUNT_HW_CACHE_REFERENCES,
        .read_format = PERF_FORMAT_TOTAL_TIME_ENABLED|PERF_FORMAT_TOTAL_TIME_ENABLED,
        .disabled = 1,
      }
    },
  };

static libperf_simple *
lps_new(void) {
  dTHX;
  const char *err = NULL;
  libperf_simple *obj;

  Newxz(obj, 1, libperf_simple);

  obj->threads = perf_thread_map__new_dummy();
  if (!obj->threads) {
    err = "Cannot create thread map";
    goto fail;
  }
  /* current process */
  perf_thread_map__set_pid(obj->threads, 0, 0);

  obj->evlist = perf_evlist__new();
  if (!obj->evlist) {
    err = "Cannot create evlist";
    goto fail;
  }

  for (int i = 0; i < C_ARRAY_LENGTH(ev_attr); ++i) {
    struct perf_evsel *evsel = perf_evsel__new(&ev_attr[i].attr);
    if (!evsel) {
      err = Perl_form(aTHX_ "Cannot make evsel %d", i);
      goto fail;
    }

    perf_evlist__add(obj->evlist, evsel);
  }
  perf_evlist__set_maps(obj->evlist, NULL, obj->threads);
  if (perf_evlist__open(obj->evlist)) {
    err = "Failed to open evlist";
    goto fail;
  }

  return obj;
  
 fail:
  if (obj->evlist)
    perf_evlist__delete(obj->evlist);
  if (obj->threads)
    perf_thread_map__put(obj->threads);
  Safefree(obj);
  Perl_croak(aTHX_ "%s", err);
}

static void
lps_DESTROY(libperf_simple *obj) {
  perf_evlist__close(obj->evlist);
  perf_evlist__delete(obj->evlist);
  perf_thread_map__put(obj->threads);
  Safefree(obj);
}

static void
lps_enable(libperf_simple *obj) {
  perf_evlist__enable(obj->evlist);
}

static void
lps_disable(libperf_simple *obj) {
  perf_evlist__disable(obj->evlist);
}

#if IVSIZE > 4
#define newSVnum(x) newSVuv(x)
#else
#define newSVnum(x) newSVnv(x)
#endif

static HV *
lps_results(libperf_simple *obj) {
  dTHX;
  HV *r = newHV();

  struct perf_evsel *evsel;
  struct perf_counts_values counts;
  int i = 0;
  perf_evlist__for_each_evsel(obj->evlist, evsel) {
    perf_evsel__read(evsel, 0, 0, &counts);

    HV *entry = newHV();
    SV *entry_rv = newRV_noinc((SV*)entry);

    struct perf_event_attr *attr = perf_evsel__attr(evsel);
    hv_stores(entry, "val", newSVnum(counts.val));
    hv_stores(entry, "run", newSVnum(counts.run));
    if (attr->read_format & PERF_FORMAT_ID)
      hv_stores(entry, "id", newSVnum(counts.id));
    hv_stores(entry, "enabled", newSVnum(counts.ena));
    if (attr->read_format & PERF_FORMAT_LOST)
      hv_stores(entry, "lost", newSVnum(counts.lost));

    const char *key = ev_attr[i].key;
    hv_store(r, key, strlen(key), entry_rv, 0);

    ++i;
  }

  return r;
}

MODULE = Linux::libperf::Simple PACKAGE = Linux::libperf::Simple PREFIX=lps_

PROTOTYPES: DISABLE

Linux::libperf::Simple
lps_new(class)
  C_ARGS:

void
lps_DESTROY(Linux::libperf::Simple obj)

void
lps_enable(Linux::libperf::Simple obj)

void
lps_disable(Linux::libperf::Simple obj)

HV *
lps_results(Linux::libperf::Simple obj)

BOOT:
  libperf_init(libperf_print);
