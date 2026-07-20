-- Slice 1: Helper Function Tests

do $$
declare
    v_source uuid;
    v_target uuid;
begin
    -- normalize_namespace
    assert internal_api.normalize_namespace('  Hello World  ') = 'hello world', 'normalize_namespace trims and lowercases';

    -- normalize_slug
    assert internal_api.normalize_slug('Hello World!!') = 'hello-world', 'normalize_slug basic';
    assert internal_api.normalize_slug('  UPPER CASE  ') = 'upper-case', 'normalize_slug trims';
    assert internal_api.normalize_slug('') = 'item', 'normalize_slug empty fallback';

    -- canonicalize_relationship (returns two rows as table)
    select source_id, target_id into v_source, v_target
    from internal_api.canonicalize_relationship(
        '00000000-0000-0000-0000-000000000002'::uuid,
        '00000000-0000-0000-0000-000000000001'::uuid,
        true
    );
    assert v_source = '00000000-0000-0000-0000-000000000001'::uuid, 'canonicalize: source should be lesser';
    assert v_target = '00000000-0000-0000-0000-000000000002'::uuid, 'canonicalize: target should be greater';

    -- current_auth_issuer/subject (no JWT context)
    assert internal_api.current_auth_issuer() is null, 'current_auth_issuer null without JWT';
    assert internal_api.current_auth_subject() is null, 'current_auth_subject null without JWT';

    raise notice 'All helper function tests passed!';
end $$;
