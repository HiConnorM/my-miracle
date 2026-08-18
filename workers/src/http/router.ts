import type { Env } from '../env';
import { ApiError, json } from './responses';

/**
 * A router small enough to read in one sitting.
 *
 * `URLPattern` is built into workerd, so this needs no dependency (rule 18). Routes are
 * matched in declaration order.
 */
export interface RouteContext {
  request: Request;
  env: Env;
  params: Record<string, string>;
  url: URL;
}

type Handler = (context: RouteContext) => Promise<Response> | Response;

interface Route {
  method: string;
  pattern: URLPattern;
  handler: Handler;
}

export class Router {
  private readonly routes: Route[] = [];

  add(method: string, pathname: string, handler: Handler): this {
    this.routes.push({ method, pattern: new URLPattern({ pathname }), handler });
    return this;
  }

  get(pathname: string, handler: Handler): this {
    return this.add('GET', pathname, handler);
  }

  post(pathname: string, handler: Handler): this {
    return this.add('POST', pathname, handler);
  }

  put(pathname: string, handler: Handler): this {
    return this.add('PUT', pathname, handler);
  }

  patch(pathname: string, handler: Handler): this {
    return this.add('PATCH', pathname, handler);
  }

  delete(pathname: string, handler: Handler): this {
    return this.add('DELETE', pathname, handler);
  }

  async handle(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    for (const route of this.routes) {
      if (route.method !== request.method) continue;
      const match = route.pattern.exec({ pathname: url.pathname });
      if (!match) continue;

      const params: Record<string, string> = {};
      for (const [key, value] of Object.entries(match.pathname.groups)) {
        if (value !== undefined) params[key] = value;
      }

      try {
        return await route.handler({ request, env, params, url });
      } catch (error) {
        return toResponse(error, env);
      }
    }

    // No route matched. This is also how tables with no client surface — moderation
    // cases, moderation actions, refresh tokens, post_authorship — stay unreachable:
    // there is nothing to authorize because there is nothing to call.
    return json({ error: 'not_found' }, 404);
  }
}

function toResponse(error: unknown, env: Env): Response {
  if (error instanceof ApiError) {
    return error.toResponse();
  }

  console.error('unhandled error', error);

  // An unexpected error's message can quote a query or a request body, which in this app
  // means prayer text. It is logged, never returned — except in development, where the
  // developer is the only person who can see it.
  return json(
    {
      error: 'server_error',
      detail:
        env.MM_ENVIRONMENT === 'development' && error instanceof Error
          ? error.message
          : undefined,
    },
    500,
  );
}
