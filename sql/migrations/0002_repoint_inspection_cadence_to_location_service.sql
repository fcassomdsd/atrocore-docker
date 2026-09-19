-- Re-point InspectionCadence from the per-visit InspectedProvider to LocationService.
--
-- WHY: a cadence answers "when is this service next due an inspection?" and is
-- consumed by compliance_web's siteVisitSchedulingJob, which CREATES SiteVisits
-- from it. But `inspected_provider` is a per-site-visit junction row (it belongs
-- to a SiteVisit and a ServiceProvider) created only after a visit exists, so the
-- entity that triggers the first visit could not exist until a visit already did.
-- LocationService is authority data -- the registry of which provider offers which
-- specialties at which location -- and is therefore the correct grain. It also
-- prevents combinations that cannot exist (a radar-specialty cadence at a location
-- with no radar), which three independent required links could express.
--
-- ORDER IS LOAD-BEARING. This must run BEFORE `install-metadata.sh` +
-- `sql diff --run`. AtroCore's `sql diff` is a plain Doctrine comparator with
-- drops included, so installing the new entity definition first makes Doctrine
-- drop `inspected_provider_id` outright and the backfill below becomes impossible.
--
-- The new unique index on (deleted, location_service_id, specialty_id,
-- activity_type_id) is declared in metadata/entityDefs/InspectionCadence.json and
-- created by `sql diff --run`, NOT here -- a hand-made index under a name that
-- does not match AtroCore's convention would be dropped by the next diff. That is
-- why this script fails loudly on pre-existing duplicates: better to stop here,
-- with the offending ids named, than to have `sql diff --run` choke on DDL.
--
-- `migrate-db.sh` wraps this file in BEGIN/COMMIT itself, so it declares no
-- transaction of its own.

DO $migration$
DECLARE
    unresolved_total   integer;
    unresolved_live    integer;
    duplicate_report   text;
BEGIN
    -- Fresh-install guard: migrations run before install-metadata.sh, so on a
    -- clean clone the entity has no table yet and there is nothing to migrate.
    IF to_regclass('public.inspection_cadence') IS NULL THEN
        RAISE NOTICE 'inspection_cadence does not exist yet (fresh install) - nothing to migrate.';
        RETURN;
    END IF;

    ALTER TABLE public.inspection_cadence
        ADD COLUMN IF NOT EXISTS location_service_id character varying(36) DEFAULT NULL::character varying;

    -- Backfill only makes sense while the old column is still present. Guarded
    -- (and run through EXECUTE) so a re-run after the DROP below is a no-op
    -- rather than a parse error.
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name = 'inspection_cadence'
           AND column_name = 'inspected_provider_id'
    ) THEN
        -- inspected_provider gives us the ServiceProvider; its SiteVisit gives us
        -- the Location. That (provider, location) pair identifies the
        -- LocationService.
        --
        -- The cadence's specialty is a HARD filter, not a tiebreak. One provider
        -- routinely has several services at one location (in the demo data
        -- demo-prov-ans has both an ATS and a NAV service at demo-loc-zzzz), so
        -- (provider, location) alone is ambiguous. Preferring a specialty match
        -- but falling back to "any" would silently file a NAV cadence against the
        -- ATS service whenever location_service_specialty is sparse -- and it is
        -- sparse in practice. Better to resolve nothing and fail loudly below.
        EXECUTE $backfill$
            UPDATE public.inspection_cadence c
               SET location_service_id = (
                     SELECT ls.id
                       FROM public.location_service ls
                       JOIN public.inspected_provider ip ON ip.id = c.inspected_provider_id
                       JOIN public.site_visit sv ON sv.id = ip.site_visit_id
                      WHERE ls.deleted = false
                        AND ls.service_provider_id = ip.service_provider_id
                        AND ls.location_id = sv.location_id
                        AND (
                              c.specialty_id IS NULL
                              OR EXISTS (
                                  SELECT 1
                                    FROM public.location_service_specialty lss
                                   WHERE lss.location_service_id = ls.id
                                     AND lss.specialty_id = c.specialty_id
                              )
                            )
                      ORDER BY ls.id
                      LIMIT 1
                   )
             WHERE c.location_service_id IS NULL
               AND c.inspected_provider_id IS NOT NULL
        $backfill$;

        EXECUTE $count_all$
            SELECT count(*) FROM public.inspection_cadence
             WHERE location_service_id IS NULL AND inspected_provider_id IS NOT NULL
        $count_all$ INTO unresolved_total;

        EXECUTE $count_live$
            SELECT count(*) FROM public.inspection_cadence
             WHERE location_service_id IS NULL AND inspected_provider_id IS NOT NULL
               AND deleted = false
        $count_live$ INTO unresolved_live;

        -- Soft-deleted rows that do not resolve are acceptable: the reference
        -- database's only cadences are soft-deleted smoke tests with a NULL
        -- specialty, predating the `required` flags. A LIVE row that does not
        -- resolve means the authority data is incomplete -- stop and let an
        -- operator add the missing LocationService rather than silently
        -- discarding the link.
        IF unresolved_total > 0 THEN
            RAISE NOTICE '% cadence row(s) had no matching LocationService (% of them not deleted).',
                unresolved_total, unresolved_live;
        END IF;

        IF unresolved_live > 0 THEN
            RAISE EXCEPTION
                '% live inspection_cadence row(s) could not be mapped to a LocationService. '
                'Create the missing LocationService rows (provider + location, with the '
                'cadence''s specialty attached) and re-run this migration.', unresolved_live;
        END IF;
    END IF;

    -- The unique index is created by `sql diff --run` straight after this script,
    -- so any pre-existing duplicate must surface here, named, instead of as a
    -- Doctrine DDL failure.
    SELECT string_agg(
               format('(location_service=%s, specialty=%s, activity_type=%s) x%s',
                      coalesce(location_service_id, 'NULL'),
                      coalesce(specialty_id, 'NULL'),
                      coalesce(activity_type_id, 'NULL'),
                      n),
               '; ' ORDER BY location_service_id)
      INTO duplicate_report
      FROM (
            SELECT location_service_id, specialty_id, activity_type_id, count(*) AS n
              FROM public.inspection_cadence
             WHERE deleted = false
             GROUP BY location_service_id, specialty_id, activity_type_id
            HAVING count(*) > 1
           ) dups;

    IF duplicate_report IS NOT NULL THEN
        RAISE EXCEPTION
            'Duplicate inspection cadences would violate the new unique index: %. '
            'Resolve these before migrating.', duplicate_report;
    END IF;

    -- Dropped explicitly rather than left to Doctrine, so the outcome is
    -- deterministic and this file documents the whole change. `location_id` goes
    -- too: the location is now derived via location_service.location_id, and a
    -- second copy could disagree with it.
    ALTER TABLE public.inspection_cadence DROP COLUMN IF EXISTS inspected_provider_id;
    ALTER TABLE public.inspection_cadence DROP COLUMN IF EXISTS location_id;

    RAISE NOTICE 'inspection_cadence re-pointed to location_service.';
END
$migration$;
