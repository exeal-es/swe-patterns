---
title: "Arquitectura en capas para frontend React"
description: "En una SPA React sin fronteras internas, la lógica de negocio, el estado y el JSX se mezclan en el mismo componente, encareciendo los tests y acoplando negocio a UI. La solución separa cuatro capas — API, store, casos de uso y componentes presentacionales — cada una testeable con la herramienta más barata que le sirve."
date: 2026-09-24
tags:
  - arquitectura
  - frontend
  - react
  - testing
maturity: adopt
---

## Problema

En una SPA React sin fronteras internas, todo tiende a mezclarse dentro del componente que renderiza la pantalla: la llamada a la API, el estado de carga/error, la lógica de negocio (qué pedir, cómo combinar resultados, cuándo revalidar) y el JSX que lo pinta. El resultado es un componente que solo se puede testear montándolo entero — con mocks de `fetch`, de router, de lo que haga falta — y donde no hay forma de reutilizar la lógica en otro sitio ni de darle una historia de Storybook sin resolver antes media aplicación.

Esto se agrava con el tiempo: cuanta más lógica de negocio vive dentro del componente, más caro es cada test (jsdom + RTL + mocks en vez de una función pura con Vitest) y más frágil es la pantalla ante refactors de UI que no deberían afectar a nada de negocio.

## Solución

La idea central es separar cuatro capas con responsabilidades distintas, cada una testeable con la herramienta más barata que le sirve, y dejar que el import graph (reforzado por ESLint, no solo por convención) impida que una capa se salte a otra:

```
features/<dominio>/routes/*Route.tsx  →  features/<dominio>/useCases/*  →  store/*  →  api/resources/*
                    ↓ renderiza
        features/<dominio>/components/*.tsx   (presentacional puro)
```

### 1. `api/resources/` — un módulo por recurso del backend

Funciones async finas: reciben parámetros tipados, arman la URL/query y devuelven la respuesta tipada. Nada de estado, nada de lógica de negocio. Si el backend expone un contrato OpenAPI, genera los tipos (`openapi-typescript`) y tipa cada función contra ese schema en vez de mano:

```ts
// api/resources/customers.ts
export async function getCustomerSummary(customerId: number): Promise<CustomerSummaryDto> {
  return get<CustomerSummaryDto>(`${API_PREFIX}${path('/customers/{customerId}', { customerId: String(customerId) })}`);
}
```

### 2. `store/` — un store Zustand por dominio

El store guarda estado (datos, `loading`, `error` por cada operación) y expone acciones async que llaman a `api/resources/` y hacen `set()` con el resultado. Nada de JSX, nada de router. Cuando varias acciones repiten el mismo ciclo carga→éxito/error, extrae un helper compartido en vez de repetirlo:

```ts
// store/asyncFetch.ts — el ciclo loading/error/data que repite cada acción de fetch
export async function runFetch<T>(set: SetFn<T>, keys: AsyncFetchKeys<T>, fn: () => Promise<Partial<T>>) {
  set({ [keys.loading]: true, ...(keys.error ? { [keys.error]: null } : {}) } as Partial<T>);
  try {
    set({ ...(await fn()), [keys.loading]: false } as Partial<T>);
  } catch (error) {
    set({ [keys.loading]: false, ...(keys.error ? { [keys.error]: (error as Error).message } : {}) } as Partial<T>);
  }
}
```

```ts
// store/useCustomersStore.ts
export const useCustomersStore = create<CustomersState>()((set, get) => ({
  summary: null, summaryLoading: false, summaryError: null,
  async fetchSummary(customerId) {
    await runFetch(set, { loading: 'summaryLoading', error: 'summaryError' }, async () => ({
      summary: await getCustomerSummary(customerId),
    }));
  },
}));
```

Divide el estado por dominio (un store por feature) en vez de un store único global, más un store transversal para lo que no es dato de servidor (toasts, modales). No uses React Context para estado de dominio ni una librería de server-state aparte (React Query, SWR): el store ya cumple ese papel.

### 3. `features/<dominio>/useCases/` — la capa de orquestación de negocio

Un *use case* es una función async de negocio que orquesta una acción completa: llama a una o varias acciones del store, y coordina cruces entre stores cuando una acción tiene efectos en más de un dominio. Es la única capa con lógica de negocio no trivial, y por eso es la única que merece existir como capa aparte — si una route puede llamar a una acción del store 1:1 sin combinar nada, no hace falta interponer un use case (ver Variantes). Vive en un único módulo por feature (`useCases/index.ts`), no un archivo por función, y se testea con Vitest puro (sin DOM): stubea el store/api y comprueba que orquesta lo que dice orquestar.

```ts
// features/customers/useCases/index.ts
/** Carga el resumen del cliente, la primera página de pedidos y sus recibos — las tres en
 * paralelo, ya que ninguna depende del resultado de otra. */
export async function loadCustomer(customerId: number): Promise<void> {
  const { fetchSummary, fetchOrders, fetchReceivables } = useCustomersStore.getState();
  await Promise.all([fetchSummary(customerId), fetchOrders(customerId, { reset: true }), fetchReceivables(customerId)]);
}
```

### 4. `features/<dominio>/routes/*Route.tsx` — un contenedor por URL

Una route es el único punto de contacto entre la URL/router y el resto de la app: lee `useParams`/el store (suscripción reactiva, no pasa por `useCases/`), define los handlers que llaman a `useCases/` para cualquier cosa que mute estado, y renderiza un componente presentacional pasándole todo por props — incluida la navegación, como callback.

```tsx
// features/customers/routes/CustomerDetailRoute.tsx
export function CustomerDetailRoute() {
  const { customerId } = useParams<{ customerId: string }>();
  const summary = useCustomersStore((s) => s.summary);
  useEffect(() => { void loadCustomer(Number(customerId)); }, [customerId]);

  return (
    <CustomerSummaryView
      summary={summary}
      onChangeCreditLimit={(amount) => void changeCustomerCreditLimit(Number(customerId), amount)}
      onViewVerification={() => navigate(`/customers/${customerId}/verification`)}
    />
  );
}
```

### 5. `features/<dominio>/components/` — presentacionales puros

Reciben todo por props, sin importar `react-router-dom`, `store/` ni `useCases/`. Al no depender de nada externo se testean con Vitest + RTL sin mocks (solo props de entrada/salida esperada) y se les puede dar una historia de Storybook trivialmente — el mismo componente, montado con props fijas.

```tsx
// features/customers/components/CustomerSummaryView.tsx — sin router, sin store, sin useCases
export function CustomerSummaryView({ summary, onChangeCreditLimit, onViewVerification }: Props) {
  // ...solo JSX derivado de props
}
```

### Cómo saber que quedó bien aplicado

Cada capa se testea con la herramienta más barata que la cubre: lógica pura (mappers, use cases) con Vitest en `environment: 'node'`, sin DOM; componentes/hooks con estado propio, con Vitest + jsdom + RTL; contratos presentacionales aislados, con historias de Storybook ejecutables (`@storybook/addon-vitest`). Si para testear un use case hace falta jsdom, algo de UI se ha colado dentro.

El límite de `components/` no debe quedar en convención: una regla de ESLint (`no-restricted-imports` acotada a `features/*/components/**`) lo hace cumplir en CI. Si un componente de `components/` necesita un mock de router o de store para renderizar, esta regla debería haberlo bloqueado antes de llegar a review:

```ts
// eslint.config.js
const componentBoundaryRule = {
  'no-restricted-imports': ['error', {
    patterns: [
      { group: ['@/store/*', '@/features/*/useCases', '@/features/*/useCases/*'],
        message: "features/*/components/** must stay presentational — no store or use case access." },
      { group: ['react-router-dom'],
        message: "features/*/components/** must stay presentational — no routing." },
    ],
  }],
};
```

## Variantes

Cuando ninguna route de una feature combina más de una llamada al store ni cruza dominios, la capa `useCases/` no aporta nada — la route puede llamar a las acciones del store directamente. En ese caso el resto del patrón se mantiene igual (store con el mismo ciclo carga/error, componentes presentacionales puros con Storybook, routes que orquestan y pasan props), solo que sin ese nivel intermedio. Si más adelante una acción empieza a necesitar orquestación real (combinar dos fetches, tocar dos stores, revalidar tras una mutación), es el momento de extraer `useCases/` para esa feature — no antes.

## Ejemplos

En [El Baúl](https://github.com/ne2-studio/el-baul) y en un repo propietario de administración interna (sin enlace) las cuatro capas están completas, con la regla de ESLint que impide que `components/` importe `store/`, `useCases/` o `react-router-dom`. En [CashClarity](https://github.com/ne2-studio/cashclarity) se usa la variante sin `useCases/`: las routes llaman al store Zustand directamente, ya que sus acciones no necesitan orquestación adicional; el resto (componentes puros con Storybook, store con el mismo ciclo carga/error) es igual.
