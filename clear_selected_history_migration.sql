-- Run this migration in Supabase SQL Editor before using the new manager action.
create or replace function public.clear_selected_history(p_event_ids uuid[])
returns integer language plpgsql security definer set search_path = '' as $$
declare removed integer;
begin
  if not private.is_manager() then raise exception 'manager_required'; end if;
  if coalesce(array_length(p_event_ids,1),0)<1 or array_length(p_event_ids,1)>1000 then
    raise exception 'invalid_event_selection';
  end if;
  delete from public.inventory_events where id = any(p_event_ids);
  get diagnostics removed = row_count;
  return removed;
end;
$$;
revoke all on function public.clear_selected_history(uuid[]) from public, anon;
grant execute on function public.clear_selected_history(uuid[]) to authenticated;
