// T-Meet: always-visible "Invite" button so moderators can copy the room link again
// after closing the session details popup.
import React, { useState } from 'react';
import { defineMessages, useIntl } from 'react-intl';
import styled from 'styled-components';
import useMeeting from '/imports/ui/core/hooks/useMeeting';
import useCurrentUser from '/imports/ui/core/hooks/useCurrentUser';
import Button from '/imports/ui/components/common/button/component';
import { notify } from '/imports/ui/services/notification';
import deviceInfo from '/imports/utils/deviceInfo';

const intlMessages = defineMessages({
  inviteLabel: {
    id: 'app.navBar.inviteLabel',
    description: 'Label of the button that copies the meeting invite link',
    defaultMessage: 'Invite',
  },
  inviteTooltip: {
    id: 'app.navBar.inviteTooltip',
    description: 'Tooltip of the invite button',
    defaultMessage: 'Copy the invite link',
  },
  inviteCopied: {
    id: 'app.navBar.inviteCopied',
    description: 'Toast shown after the invite link was copied',
    defaultMessage: 'Invite link copied. Paste it to share with your learners.',
  },
});

const COPIED_TIMEOUT = 3000;

const InviteButton = styled(Button)`
  border-radius: 1.1rem;
  font-size: 0.9rem;
  margin-right: 0.5rem;
`;

const NavBarInviteButton: React.FC = () => {
  const intl = useIntl();
  const [copied, setCopied] = useState(false);

  const { data: meeting } = useMeeting((m) => ({ loginUrl: m.loginUrl }));
  const { data: currentUser } = useCurrentUser((u) => ({ isModerator: u.isModerator }));

  const loginUrl = meeting?.loginUrl;
  // Same rule as the session details popup: only moderators see the join link.
  if (!loginUrl || !currentUser?.isModerator) return null;

  const copyLink = async () => {
    await navigator.clipboard.writeText(loginUrl);
    setCopied(true);
    notify(intl.formatMessage(intlMessages.inviteCopied), 'success', 'link');
    setTimeout(() => setCopied(false), COPIED_TIMEOUT);
  };

  return (
    <InviteButton
      data-test="tmeetInviteButton"
      onClick={copyLink}
      icon={copied ? 'check' : 'link'}
      color="primary"
      size="md"
      label={intl.formatMessage(intlMessages.inviteLabel)}
      tooltipLabel={intl.formatMessage(intlMessages.inviteTooltip)}
      hideLabel={deviceInfo.isPhone}
      circle={deviceInfo.isPhone}
    />
  );
};

export default NavBarInviteButton;
