/** Apply the build-time Web UI mount point to a same-origin application path. */
export function webPath(path: string, base = import.meta.env.BASE_URL || '/'): string {
    if (!path.startsWith('/') || path.startsWith('//')) return path;
    const prefix = base.replace(/\/$/, '');
    return prefix && path !== prefix && !path.startsWith(`${prefix}/`) ? `${prefix}${path}` : path;
}
