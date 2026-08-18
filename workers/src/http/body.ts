import { invalid } from './responses';

export async function readJson(request: Request): Promise<Record<string, unknown>> {
  let parsed: unknown;
  try {
    parsed = await request.json();
  } catch {
    throw invalid('body must be JSON');
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw invalid('body must be a JSON object');
  }
  return parsed as Record<string, unknown>;
}

export function requireString(
  body: Record<string, unknown>,
  field: string,
  options: { min?: number; max?: number } = {},
): string {
  const value = body[field];
  if (typeof value !== 'string') throw invalid(`${field} must be a string`);
  const trimmed = value.trim();
  const { min = 1, max = 5000 } = options;
  if (trimmed.length < min) throw invalid(`${field} is too short`);
  if (trimmed.length > max) throw invalid(`${field} is too long`);
  return trimmed;
}

export function optionalString(
  body: Record<string, unknown>,
  field: string,
  options: { max?: number } = {},
): string | undefined {
  if (body[field] === undefined || body[field] === null) return undefined;
  return requireString(body, field, options);
}

export function requireEnum<T extends string>(
  body: Record<string, unknown>,
  field: string,
  allowed: readonly T[],
): T {
  const value = body[field];
  if (typeof value !== 'string' || !allowed.includes(value as T)) {
    throw invalid(`${field} must be one of: ${allowed.join(', ')}`);
  }
  return value as T;
}

export function optionalBoolean(body: Record<string, unknown>, field: string): boolean {
  const value = body[field];
  if (value === undefined || value === null) return false;
  if (typeof value !== 'boolean') throw invalid(`${field} must be a boolean`);
  return value;
}

export function requireNumber(body: Record<string, unknown>, field: string): number {
  const value = body[field];
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw invalid(`${field} must be a number`);
  }
  return value;
}

/** Page sizes are clamped so a client cannot ask for the whole table. */
export function pageLimit(url: URL, fallback = 25, max = 50): number {
  const raw = Number(url.searchParams.get('limit'));
  if (!Number.isFinite(raw) || raw <= 0) return fallback;
  return Math.min(Math.floor(raw), max);
}
