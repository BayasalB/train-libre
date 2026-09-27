/// Stable legacy route IDs: Today=0, Workout=1, Progress=2, Food=3, More=4.
/// Visual order is separate so existing deep links retain their meaning.
const mainTabOrder = [0, 3, 1, 2, 4];
int mainTabPosition(int routeId) => mainTabOrder.indexOf(routeId);
int mainTabRoute(int position) => mainTabOrder[position];
